//
//  ViewController.swift
//  WistiaKitDemoMasterClass
//
//  Created by David Cole on 3/21/17.
//  Copyright © 2017 David Cole. All rights reserved.
//

import UIKit
import WistiaKit

class ViewController: UIViewController {
    let wistiaPlayerVC = WistiaPlayerViewController(referrer: "https://masterclass.com")
    
    @IBOutlet weak var hashedIDTextField: UITextField!

    @IBAction func playTapped(_ sender: Any) {
        if let hashedID = hashedIDTextField.text {
            wistiaPlayerVC.replaceCurrentVideoWithVideo(forHashedID: hashedID)
            self.present(wistiaPlayerVC, animated: true, completion: nil)
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}

