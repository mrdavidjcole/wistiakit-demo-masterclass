//
//  _WistiaPlayer.swift
//  WistiaKit internal
//
//  Created by Daniel Spinosa on 1/7/16.
//  Copyright © 2016 Wistia, Inc. All rights reserved.
//
//  WistiaPlayer presents a convenient facade in front of AVPlayer.
//
//  Create a WistiaPlayer with the hashed_id of a media, and it will play the best
//  asset for the device.
//
//  Use the WistiaPlayerDelegate as a convenient mechanism to respond to key events
//  in the video playback lifecycle.
//
//  The underlying AVPlayer is not exposed to facilitate the proper collection and reporting
//  of important Wistia statistics.  Common functionality of the AVPLayer is available through
//  public API directly on WistiaPlayer and through the delegate.

import UIKit
import AVKit
import AVFoundation

internal extension WistiaPlayer {

    //MARK: - Private Helpers

    internal func readyPlayback(for media: WistiaMedia, choosingAssetWithSlug slug: String?) {
        self.media = media
        self.state = .videoPreLoading(media: media)

        //-- Out with the old (always, if applicable)
        removePlayerItemObservers(for: avPlayer.currentItem)
        avPlayer.replaceCurrentItem(with: nil)
        WistiaStatsManager.sharedInstance.removeEventCollector(statsCollector)

        guard media.status != .failed else {
            self.state = .videoLoadingError(description: "Media \(media.hashedID) failed processing", problemMedia: media, problemAsset: nil)
            return
        }

        guard media.status != .queued else {
            self.state = .videoLoadingError(description: "Media \(media.hashedID) has not started processing", problemMedia: media, problemAsset: nil)
            return
        }

        //assuming playback on local device, target asset width is the largest dimension of device
        let targetAssetWidth = media.isSpherical() ? SphericalTargetAssetWidth : Int64(max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))

        do {
            let url = try bestPlaybackUrl(for: media, andAssetWithSlug: slug, requiringHLS: self.requireHLS, atTargetWidth: targetAssetWidth)

            //-- In with the new
            self.state = .videoLoading
            statsCollector = WistiaStatsManager.sharedInstance.newEventCollector(forMedia: media, withReferrer: self.referrer)

            // There is no officially sanctioned way to set headers on an AVURLAsset request.
            // WebKit uses AVURLAssetHTTPHeaderFieldsKey, but it's private.
            // Other solutions are cumbersome and this doesn't feel too brittle since it's used by WebKit...
            let avAsset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Referer": self.referrer]])
            let avPlayerItem = AVPlayerItem(asset: avAsset)
            addPlayerItemObservers(for: avPlayerItem)
            avPlayer.replaceCurrentItem(with: avPlayerItem)
        }
        catch URLDeterminationError.noAsset {
            self.state = .videoLoadingError(description: "Media \(media.hashedID) has no assets compatible with this player's configuration.", problemMedia: media, problemAsset: nil)
        }
        catch URLDeterminationError.noHLSAsset {
            self.state = .videoLoadingError(description: "Media \(media.hashedID) has no HLS assets compatible with this WistiaPlayer, configured to require HLS for playback.", problemMedia: media, problemAsset: nil)
        }
        catch URLDeterminationError.assetNotReady(let asset) {
            var desc = "Asset with slug \(asset.slug ?? "n/a"), for media \(media.hashedID), is not ready."
            if media.status == .processing {
                desc += "  Media is still processing."
            }
            self.state = .videoLoadingError(description: desc, problemMedia: media, problemAsset: asset)
        }
        catch {
            self.state = .videoLoadingError(description: "Something unexpected happened looking for an asset to play for media \(media.hashedID).", problemMedia: media, problemAsset: nil)
        }
    }

    //Web makes decisions in a more complicated environment:
    //https://github.com/wistia/wistia/blob/master/app/assets/javascripts/external/E-v1/_judge_judy.coffee
    //
    //We just need HLS (if required), otherwise mp4.  If there are options, we pick the best sized.
    internal func bestPlaybackUrl(for media: WistiaMedia, andAssetWithSlug assetSlug: String?, requiringHLS requireHLS: Bool, atTargetWidth targetWidth: Int64) throws -> URL {
        //If a particular asset is requested using the slug, that overrides all other configuration
        if let slug = assetSlug {
            if let assetMatchingSlug = (media.assets.filter { $0.slug == slug }).first {
                // The DataAPI v1 only returns ready assets (thus checking for nil), the embed API will include status
                guard assetMatchingSlug.status == nil || assetMatchingSlug.status == .ready
                    else { throw URLDeterminationError.assetNotReady(asset: assetMatchingSlug) }
                delegate?.wistiaPlayer(self, willLoadVideoForMedia: media, usingAsset: assetMatchingSlug, usingHLSMasterIndexManifest: false)
                return assetMatchingSlug.url
            } else {
                throw URLDeterminationError.noAsset
            }
        }

        // If HLS is available, we prefer it
        if media.hasHlsAssets() {
            delegate?.wistiaPlayer(self, willLoadVideoForMedia: media, usingAsset: nil, usingHLSMasterIndexManifest: true)
            return media.hlsMasterIndexManifestURL

        }
        else if requireHLS {
            // if HLS is required, but unavailable
            throw URLDeterminationError.noHLSAsset
        }

        // We can also playback mp4 assets
        let playableAssets = media.assets.filter { $0.type.lowercased().contains("mp4") }
        if let asset = largestAsset(in: playableAssets, withoutGoingUnder: targetWidth) {
            // The DataAPI v1 only returns ready assets (thus checking for nil), the embed API will include status
            guard asset.status == nil || asset.status == .ready
                else { throw URLDeterminationError.assetNotReady(asset: asset) }
            delegate?.wistiaPlayer(self, willLoadVideoForMedia: media, usingAsset: asset, usingHLSMasterIndexManifest: false)
            return asset.url
        } else {
            throw URLDeterminationError.noAsset
        }
    }

    internal enum URLDeterminationError : Error {
        case noAsset
        case noHLSAsset
        case assetNotReady(asset:WistiaAsset)
    }

    //NB: May go under in size if there are no assets at least as large as the targetWidth
    internal func largestAsset(in assets:[WistiaAsset], withoutGoingUnder targetWidth:Int64) -> WistiaAsset? {
        let sortedAssets = assets.sorted { $0.width > $1.width }
        var largestWithoutGoingUnder:WistiaAsset? =  sortedAssets.first

        for asset in sortedAssets {
            if asset.width >= targetWidth {
                largestWithoutGoingUnder = asset
            }
        }

        return largestWithoutGoingUnder
    }

    internal func log(_ event:WistiaMediaEventCollector.EventType, withValue value:String? = nil) {
        if let val = value {
            statsCollector?.log(event, withValue: val)
        } else {
            statsCollector?.log(event, withValue: avPlayer.currentTime().seconds.description)
        }
    }

    //MARK:- Value add observation

    internal func playerItem(_ playerItem:AVPlayerItem, statusWas oldStatus:AVPlayerStatus?, changedTo newStatus:AVPlayerStatus){
        switch newStatus {
        case .failed:
            self.state = .videoPlaybackError(description: "Player Item Failed")
        case .unknown:
            break
        case .readyToPlay:
            //Unkown means "hasn't tried to load media"
            if oldStatus == .unknown {
                self.state = .videoReadyForPlayback
                log(.initialized)
            }
        }
    }

    internal func player(_ player:AVPlayer, rateChangedTo rate:Float){
        DispatchQueue.main.async { () -> Void in
            self.delegate?.wistiaPlayer(self, didChangePlaybackRateTo: rate)
        }
        if preventIdleTimerDuringPlayback {
            UIApplication.shared.isIdleTimerDisabled = (rate > 0.0)
        }
        log(.playbackRateChange, withValue: String(format:"%f", rate))
    }

    internal func onPlayerTimeUpdate(of time:CMTime) {
        //time and duration must both be valid and definite
        guard (time.flags.contains(.valid)) else { return }
        guard let duration = avPlayer.currentItem?.duration , duration.flags.contains(.valid) else { return }
        guard (!time.flags.contains(.indefinite) && !duration.flags.contains(.indefinite)) else { return }

        DispatchQueue.main.async { () -> Void in
            self.delegate?.wistiaPlayer(self, didChangePlaybackProgressTo: Float(time.seconds / duration.seconds), atCurrentTime: time, ofDuration: duration)
        }

        DispatchQueue.main.async { () -> Void in
            self.captionsRenderer.onPlayerTimeUpdate(time)
        }

        //reduced resolution and jitter implemented in the stats collector
        log(.update)
    }

    internal func playerItemPlayedToEnd(_ notification:Notification) {
        DispatchQueue.main.async {
            self.delegate?.didPlayToEndTime(of: self)
        }
        log(.end)
    }

    internal func playerItemFailedToPlayToEnd(_ notification:Notification) {
        //ignoring for now
    }

    //MARK: - Raw Observeration

    internal func addPlayerItemObservers(for playerItem:AVPlayerItem) {
        playerItem.addObserver(self, forKeyPath: "status", options: [.old, .new], context: &playerItemContext)
        NotificationCenter.default.addObserver(self, selector: #selector(WistiaPlayer.playerItemPlayedToEnd(_:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: playerItem)
        NotificationCenter.default.addObserver(self, selector: #selector(WistiaPlayer.playerItemFailedToPlayToEnd(_:)), name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: playerItem)
    }

    internal func removePlayerItemObservers(for playerItem:AVPlayerItem?){
        playerItem?.removeObserver(self, forKeyPath: "status", context: &playerItemContext)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: playerItem)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: playerItem)
    }

    internal func addPlayerObservers(for player:AVPlayer) {
        player.addObserver(self, forKeyPath: "rate", options: .new, context: &playerContext)
        //observe time updates every 0.1 seconds
        periodicTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 10),
                                                              queue: nil,
                                                              using: { [weak self] (time) in
            self?.onPlayerTimeUpdate(of: time)
        })
    }

    internal func removePlayerObservers(for player:AVPlayer?) {
        if let player = player {
            player.removeObserver(self, forKeyPath: "rate", context: &playerContext)
            player.removeTimeObserver(periodicTimeObserver!)
        }
    }

    internal func _wkObserveValue(forKeyPath keyPath: String?, ofObject object: AnyObject?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer) {
        if context == &playerItemContext {
            if let newValue = change?[NSKeyValueChangeKey.newKey] as? Int, let newStatus = AVPlayerStatus(rawValue: newValue), let playerItem = object as? AVPlayerItem , keyPath == "status" {
                let oldStatus:AVPlayerStatus?
                if let oldValue = change?[NSKeyValueChangeKey.oldKey] as? Int {
                    oldStatus = AVPlayerStatus(rawValue: oldValue)
                } else {
                    oldStatus = nil
                }
                self.playerItem(playerItem, statusWas: oldStatus, changedTo: newStatus)
            } else {
                assertionFailure("Bad observation configuration on playerItem")
            }

        } else if context == &playerContext {
            if let newRate = change?[NSKeyValueChangeKey.newKey] as? Float
                , keyPath == "rate" {
                self.player(avPlayer, rateChangedTo:newRate)
            } else {
                assertionFailure("Bad observation configuration on player")
            }
            
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

}


