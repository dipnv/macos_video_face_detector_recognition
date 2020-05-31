/**
    PlayerViewController.swift
    avplayer

    Created by Jerry Hale on 9/1/19
    Copyright © 2019 jhale. All rights reserved
 
 This file is part of avplayer.

 avplayer is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 avplayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with avplayer.  If not, see <https://www.gnu.org/licenses/>.

*/

import Cocoa
import AVFoundation

//import UIKit
import AVKit
import Vision
//import ARKit
import CoreML
import SceneKit

private var VIEW_CONTROLLER_KVOCONTEXT = 0
private var CURRENT_TIME_KVOCONTEXT = 0

class PlayerViewController: NSViewController
{
    @IBOutlet weak var colorWell: NSColorWell!
    @IBOutlet weak var smpteTime: NSTextField!
    @IBOutlet weak var playerView: NSView!
    @IBOutlet weak var volumeSlider: NSSlider!
    @IBOutlet weak var playPauseBtn: NSButton!
    
    @IBOutlet weak var noVideoLabel: NSTextField!
    @IBOutlet weak var unplayableLabel: NSTextField!
    
    @IBOutlet weak var formatText: NSTextField!
    @IBOutlet weak var frameRateText: NSTextField!
    @IBOutlet weak var currentSizeText: NSTextField!

    @objc var scrubberSlider = Slider.init(frame: NSMakeRect(SCRUBBER_LEFT_ANCHOR, 36.0, SCRUBBER_WIDTH_ANCHOR, 24.0))
    @objc dynamic var currentTime:Double = 0.0
    @objc var player = AVPlayer()
    var videoOutput: AVPlayerItemVideoOutput?
    
    var faceFrameView = NSView.init(frame: NSMakeRect(SCRUBBER_LEFT_ANCHOR, 36.0, SCRUBBER_WIDTH_ANCHOR, 24.0))
    var faceViewArr: [NSView] = [NSView](repeating: NSView.init(), count: 5)
    var firstMLRecognization =  NSTextField.init(frame: NSMakeRect(38, 38, 50, 20))
    private var playerLayer:AVPlayerLayer!              //  movie AVPlayerLayer
    private var boundsObserver: NSKeyValueObservation?  //  observe for PlayerView bounds changes
    private var duration:CMTime = CMTime.zero           //  movie duration
    
    var frameRate:Float = 0.0
    var smpteObserverToken: Any?
    var sliderObserverToken: Any?
    private var countFaces: Int = 0
  
    var rate: Float
    {
        get { return player.rate }
        set { player.rate = newValue }
    }
  
    var volume: Float { get { return player.volume } }

    var playerItem: AVPlayerItem? = nil
    {
        didSet {
            //  if needed, configure player item here before associating it with a player.
            //  (example: adding outputs, setting text style rules, selecting media options)
            player.replaceCurrentItem(with: self.playerItem)
        }
    }
    //  MARK: IBAction
    @IBAction func setBackgroundColor(_ sender: Any)
    {
        playerView.layer?.backgroundColor = (sender as! NSColorWell).color.cgColor

        do
        {
            let colorData = try NSKeyedArchiver.archivedData(withRootObject: (sender as! NSColorWell).color, requiringSecureCoding: false)
            UserDefaults.standard.set(colorData, forKey: LAYER_BACK_COLOR)
        } catch { print("NSKeyedArchiver.archivedData error") }
    }

    @IBAction func setVolume(_ sender: NSSlider) { player.volume = sender.floatValue }
    @IBAction func playPauseBtnPressed(_ sender: NSButton)
    {
        if player.rate != 1.0
        {
            //  if at the end of video
            //  reset player to CMTime.zero
            if currentTime == CMTimeGetSeconds(duration)
            {
                currentTime = 0.0
                player.seek(to: CMTime.zero, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
            }
            
            player.play()
        }
        else { player.pause() }
        
        sender.title = player.rate == 0.0 ? "Play" : "Pause"
    }
    
    @IBAction func stepForward(_ sender: NSButton)
    {
        if player.rate != 0.0 { player.pause(); playPauseBtn.title = "Play"; }  //  pause player

        if player.currentItem!.canStepForward { player.currentItem?.step(byCount: 1) }
    }
   
    @IBAction func stepBackward(_ sender: NSButton)
    {
        if player.rate != 0.0 { player.pause(); playPauseBtn.title = "Play"; }  //  pause player

        if player.currentItem!.canStepBackward { player.currentItem?.step(byCount: -1) }
    }

    @IBAction func fastForward(_ sender: NSButton)
    {
        if player.rate != 0.0 { player.pause(); playPauseBtn.title = "Play"; }  //  pause player

        if player.rate < 2.0 { player.rate = 2.0 }
        else if player.rate < 8.0 { player.rate += 2.0 }
    }

    @IBAction func fastBackward(_ sender: NSButton)
    {
        if player.rate != 0.0 { player.pause(); playPauseBtn.title = "Play"; }  //  pause player

        if player.rate > -2.0 { player.rate = -2.0 }
        else if player.rate > -8.0 { player.rate -= 2.0 }
    }

    func updateAVVideoRectSize()
    {
        let width = self.playerLayer.videoRect.size.width
        let height = self.playerLayer.videoRect.size.height
        if width > 0 && height > 0
        {
            self.currentSizeText.stringValue = Int(width).description
                 + " x " + Int(height).description
        }
    }

    //  MARK: @objc
    @objc private func toggleTimeCodeDisplay() { smpteTime.isHidden = !smpteTime.isHidden }
    @objc dynamic var movieCurrentTime: Double
    {
        get
        {
            if player.currentItem == nil { return (0.0) }
            else { return (currentTime) }
        }

        set
        {
            let newTime = CMTimeMakeWithSeconds(newValue, preferredTimescale: 10000)
            
            currentTime = newValue
            player.seek(to: newTime, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
         }
    }

    //  MARK: overrides
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?)
    {
        //  make sure the this KVO callback was intended for this view controller
        guard context == &VIEW_CONTROLLER_KVOCONTEXT else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        if keyPath == #keyPath(PlayerViewController.player.currentItem.duration)
        {
            //  handle NSNull value for NSKeyValueChangeNewKey
            //  i.e. when `player.currentItem` is nil
            if let durationAsValue = change?[NSKeyValueChangeKey.newKey] as? NSValue
            {
                duration = durationAsValue.timeValue
            }
            else { duration = CMTime.zero }

            let hasValidDuration = duration.isNumeric && duration.value != 0

            scrubberSlider!.resetMarkers()

            scrubberSlider!.isEnabled = hasValidDuration
            scrubberSlider!.floatValue = hasValidDuration ? Float(CMTimeGetSeconds(player.currentTime())) : 0.001
            scrubberSlider!.maxValue =  hasValidDuration ? Double(CMTimeGetSeconds(duration)) : 0.001

            frameRateText.stringValue = hasValidDuration ? frameRate.truncate(places: 3).description : ""

            playPauseBtn.isEnabled = hasValidDuration

            updateAVVideoRectSize()
        }
        else if keyPath == #keyPath(PlayerViewController.player.currentItem.status)
        {
            //    display error if status becomes `.Failed`

            //  handle NSNull value for NSKeyValueChangeNewKey
            //  i.e. when `player.currentItem` is nil
            let newStatus: AVPlayerItem.Status

            if let newStatusAsNumber = change?[NSKeyValueChangeKey.newKey] as? NSNumber
            {
                newStatus = AVPlayerItem.Status(rawValue: newStatusAsNumber.intValue)!
                 self.setUpOutput()
            }
            else { newStatus = .unknown }

            if newStatus == .failed
            {
                handleErrorWithMessage(player.currentItem?.error?.localizedDescription, error:player.currentItem?.error)
            }
            
//            switch keyPath {
//            case #keyPath(AVPlayerItem.status):
//                if newStatus == .readyToPlay {
//                    self.setUpOutput()
//                }
//                break
//            default: break
//            }
        }
    }
    //  trigger KVO for anyone observing our properties
    //  affected by player and player.currentItem.duration
    override class func keyPathsForValuesAffectingValue(forKey key: String) -> Set<String>
    {
        let affectedKeyPathsMappingByKey: [String: Set<String>] = [
            "duration":     [#keyPath(PlayerViewController.player.currentItem.duration)],
            "rate":         [#keyPath(PlayerViewController.player.rate)]
        ]
        
        return affectedKeyPathsMappingByKey[key] ?? super.keyPathsForValuesAffectingValue(forKey: key)
    }
    
    override func viewWillDisappear()
    { super.viewWillDisappear(); print("PlayerViewController viewWillDisappear")
        
        //  remove all Observers
        NotificationCenter.default.removeObserver(self, name: Notification.Name(rawValue: NOTIF_TOGGLETIMECODEDISPLAY), object: nil)
        
        boundsObserver?.invalidate()
    }

    override func viewWillAppear()
    { super.viewWillAppear(); print("PlayerViewController viewWillAppear")
        //  set scrubberSlider Constraints
        scrubberSlider!.translatesAutoresizingMaskIntoConstraints = false
        scrubberSlider!.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant:SCRUBBER_LEFT_ANCHOR).isActive = true
        scrubberSlider!.widthAnchor.constraint(equalToConstant: SCRUBBER_WIDTH_ANCHOR).isActive = true

        if USE_DEFAULT_MOV { playPauseBtn.title = "Pause"; player.play() }
        else { playPauseBtn.title = "Play" }
        
        //  observe for changes to AVPlayerLayer
        //  videoRect and update Current Size
        boundsObserver = view.observe(\.frame, options: [.new, .initial])
        { object, change in self.updateAVVideoRectSize() }
    }
    
    override func viewDidLoad()
    { super.viewDidLoad(); print("PlayerViewController viewDidLoad")

        //  error label Constraints
        noVideoLabel.translatesAutoresizingMaskIntoConstraints = false
        unplayableLabel.translatesAutoresizingMaskIntoConstraints = false
        noVideoLabel.centerXAnchor.constraint(equalTo: playerView.centerXAnchor).isActive = true
        noVideoLabel.centerYAnchor.constraint(equalTo: playerView.centerYAnchor).isActive = true
        unplayableLabel.centerXAnchor.constraint(equalTo: playerView.centerXAnchor).isActive = true
        unplayableLabel.centerYAnchor.constraint(equalTo: playerView.centerYAnchor).isActive = true

        //  set up PlayerLayer
        playerLayer = AVPlayerLayer(player: player)

        playerLayer.videoGravity = .resizeAspect
        playerLayer.autoresizingMask = [.layerHeightSizable, .layerWidthSizable]
        playerLayer.frame = playerView.bounds

        playerView.wantsLayer = true
        playerView.layer?.addSublayer(playerLayer)

        //  set up Slider
        scrubberSlider!.autoresizingMask = [.minXMargin]
        scrubberSlider!.minValue = 0.0
        scrubberSlider!.maxValue = 0.0
        
        scrubberSlider!.select(scrubberSlider?.markerScrub)
        view.addSubview(scrubberSlider!)
        
        faceFrameView.wantsLayer = true
        faceFrameView.layer?.backgroundColor = NSColor.clear.cgColor
        faceFrameView.isHidden = true
        playerLayer.addSublayer(faceFrameView.layer!)
        
        for item in faceViewArr {
            item.isHidden = true
            item.wantsLayer = true
            playerLayer.addSublayer(item.layer!)
        }
        firstMLRecognization.wantsLayer = true
//        firstMLRecognization.sizeToFit()
        firstMLRecognization.isHidden = true
        playerLayer.addSublayer(firstMLRecognization.layer!)

        //  get PlayerView back color prefs
        let prefs = UserDefaults.standard.data(forKey: LAYER_BACK_COLOR)
         
        if prefs == nil   //    first app launch
        {
            do
            {
                 let colorData = try NSKeyedArchiver.archivedData(withRootObject: NSColor.black, requiringSecureCoding: false)
                 UserDefaults.standard.set(colorData, forKey: LAYER_BACK_COLOR)
             } catch { print("NSKeyedArchiver.archivedData error") }

             playerView.layer?.backgroundColor = NSColor.black.cgColor
         }
         else
         {
            do
            {
                if let colorData = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(prefs!)
                {
                    playerView.layer?.backgroundColor = (colorData as! NSColor).cgColor
                    colorWell.color = colorData as! NSColor
                }
            } catch { print("NSKeyedUnarchiver.unarchiveTopLevelObjectWithData error") }
        }

        //  set up observer to update SMPTE display
        //  observer only runs while player is playing
         smpteObserverToken =
            player.addPeriodicTimeObserver(forInterval: CMTimeMakeWithSeconds(0.02, preferredTimescale: 100), queue: DispatchQueue.main)
        { (elapsedTime: CMTime) -> Void in
            
            if !self.smpteTime.isHidden
            {
                let time = Float(CMTimeGetSeconds(self.player.currentItem?.currentTime() ?? CMTime.zero))
                let frame = Int(time * self.frameRate)
                let FF = Int(Float(frame).truncatingRemainder(dividingBy: self.frameRate))
                let seconds = Int(Float(frame - FF) / self.frameRate)
                let SS = seconds % 60
                let MM = (seconds % 3600) / 60
                let HH = seconds / 3600

                self.smpteTime.stringValue = String(format: "%02i:%02i:%02i:%02i", HH, MM, SS, FF)
            }
        
        } as AnyObject

        //  set up observer to update slider
        //  observer only runs while player is playing
        //  just needs to be fast enough for smooth animation
        sliderObserverToken =
            player.addPeriodicTimeObserver(forInterval: CMTimeMakeWithSeconds(0.2, preferredTimescale: 100), queue: DispatchQueue.main)
         { (elapsedTime: CMTime) -> Void in

            if CMTimeGetSeconds(elapsedTime) == CMTimeGetSeconds(self.duration)
            {
                //  sync currentTime with elaspedTime in
                //  case user clicks on PlayBtn here
                self.currentTime = CMTimeGetSeconds(elapsedTime)
                self.player.pause()
                self.playPauseBtn.title = "Play"
            }
            else
            {
                self.willChangeValue(forKey: "movieCurrentTime")
                self.currentTime = Double(CMTimeGetSeconds(self.player.currentTime()))
                self.didChangeValue(forKey: "movieCurrentTime")
            }
        } as AnyObject

        //  bind movieCurrentTime var to scrubberSlider.value
        bind(NSBindingName(rawValue: "movieCurrentTime"), to: scrubberSlider as Any, withKeyPath: "value", options: nil)
        //  start observing for changes to movieCurrentTime
        addObserver(scrubberSlider!, forKeyPath: "movieCurrentTime", options: [.new, .initial], context: &CURRENT_TIME_KVOCONTEXT)

        //  KVO state change
        addObserver(self, forKeyPath: #keyPath(PlayerViewController.player.currentItem.duration), options: [.new, .initial], context: &VIEW_CONTROLLER_KVOCONTEXT)
        addObserver(self, forKeyPath: #keyPath(PlayerViewController.player.currentItem.status), options: [.new, .initial], context: &VIEW_CONTROLLER_KVOCONTEXT)

        ////    toggleTimeCodeDisplay()
        NotificationCenter.default.addObserver(self, selector: #selector(toggleTimeCodeDisplay),
                                               name: Notification.Name(rawValue: NOTIF_TOGGLETIMECODEDISPLAY), object: nil)
        
        player.currentItem?.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayerItem.status),
            options: [.initial, .old, .new],
            context: nil)
          player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: DispatchQueue(label: "videoProcessing", qos: .background),
            using: { time in
              self.doThingsWithFaces()
          })
//          self.player = player
        
    }    

    func setUpOutput() {
      guard self.videoOutput == nil else { return }
      let videoItem = player.currentItem!
        if videoItem.status != AVPlayerItem.Status.readyToPlay {
        // see https://forums.developer.apple.com/thread/27589#128476
        return
      }

      let pixelBuffAttributes = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ] as [String: Any]

      let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBuffAttributes)
      videoItem.add(videoOutput)
      self.videoOutput = videoOutput
    }

    func getNewFrame() -> CVPixelBuffer? {
      guard let videoOutput = videoOutput, let currentItem = player.currentItem else { return nil }

      let time = currentItem.currentTime()
      if !videoOutput.hasNewPixelBuffer(forItemTime: time) { return nil }
      guard let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return nil }
      return buffer
    }

    func doThingsWithFaces() {
        
        guard let pixelBuffer = getNewFrame() else { return }
        // some CoreML / Vision things on that.
        // There are numerous examples with this
        guard let model = try? VNCoreMLModel(for: tmpModel().model) else {
            fatalError("***ml: Unable to load model")
        }
        
        let ciImg: CIImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext(options: nil)
        let opt = CIDetectorAccuracyHigh
        let detector = CIDetector(ofType: CIDetectorTypeFace, context: ctx, options: [CIDetectorAccuracy: opt])
        let features = detector?.features(in: ciImg)
        let count = (features?.count)!
        
        
        
        if count > 0
        {
            self.vnFaceRecognition(pixelBuffer, mlModel: model)
               
            for item in  (self.playerItem?.asset.tracks)! {
                if item.mediaType == .video {
                    let formatDesc: CMFormatDescription = item.formatDescriptions[0] as! CMFormatDescription
                    let dimension =  CMVideoFormatDescriptionGetDimensions(formatDesc)
//                    if let width = dimension.width {
                        let originSize = NSMakeSize(CGFloat(dimension.width), CGFloat(dimension.height))
                        self.ciFaceDetection(ciImg, features ?? [], realSize: playerLayer.videoRect.size, originSize: originSize)
//                    }
                    break
                }
                continue
            }
        }

    }
    func vnFaceRecognition(_ pixelBuffer: CVPixelBuffer, mlModel: VNCoreMLModel)
    {
        let coreMlRequest = VNCoreMLRequest(model: mlModel) {[weak self] request, error in
            guard let results = request.results as? [VNClassificationObservation],
                let topResult = results.first
                else {
                    fatalError("***: Unexpected results")
            }
            
            DispatchQueue.main.async {[weak self] in                                
                if (topResult.identifier != "Unknown") {
                    self?.firstMLRecognization.isHidden = false
                    self?.firstMLRecognization.textColor = NSColor.red
                    self?.firstMLRecognization.frame =   NSMakeRect(self!.playerLayer.videoRect.origin.x + 30,
                                                                    self!.playerLayer.videoRect.origin.y + self!.playerLayer.videoRect.size.height -     (self?.firstMLRecognization.frame.size.height)! - 30, (self?.firstMLRecognization.frame.size.width)!, (self?.firstMLRecognization.frame.size.height)!)//item.bounds
                    self?.firstMLRecognization.stringValue = topResult.identifier
                }
            }
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        DispatchQueue.global().async {
            do {
                try handler.perform([coreMlRequest])
            } catch {
                print(error)
            }
        }
    }
    
    func ciFaceDetection(_  ciImg: CIImage, _ features: [CIFeature], realSize: NSSize, originSize: NSSize)
    {
        for item in features {
            let xRatio = realSize.width/originSize.width
            let yRatio = realSize.height/originSize.height
            
            DispatchQueue.main.async {
                let index = features.firstIndex(of: item)
                self.faceViewArr[index!].isHidden = false
                
                self.faceViewArr[index!].frame =  item.bounds //realFrame
                self.faceViewArr[index!].layer?.position = NSMakePoint( (self.faceViewArr[index!].layer?.position.x)! * xRatio, (self.faceViewArr[index!].layer?.position.y)! * xRatio)
                
                let scale = CGAffineTransform(scaleX: xRatio, y: yRatio)
                let transition = CGAffineTransform(translationX: self.playerLayer.position.x - self.playerLayer.videoRect.size.width/2 , y: self.playerLayer.position.y - self.playerLayer.videoRect.size.height/2)
                let concat = scale.concatenating(transition)
                self.faceViewArr[index!].layer?.setAffineTransform(concat)
                
                self.faceViewArr[index!].layer?.borderColor = NSColor.random.cgColor
                self.faceViewArr[index!].layer?.borderWidth = 1.0
                
                self.perform(#selector(self.delayHidden), with: index, afterDelay: 0.4)
                let faceCrop = ciImg.cropped(to: item.bounds)
                let desktopURL = FileManager.default.urls(for: .sharedPublicDirectory, in: .userDomainMask).first!
                _ = faceCrop.savePNG("tmp\(String(describing: self.countFaces)).png", inDirectoryURL: desktopURL, quality: 1.0)
                
                self.countFaces += 1
                
            }
        }
        
    }
    
    @objc func delayHidden(index: Int) {
//        self.faceFrameView.isHidden = true
//        if ( index > -1 && index < faceViewArr.count ) {
//                self.faceViewArr[index].isHidden = true
//        }
         for item in faceViewArr {
        //            item = NSView.init()
                    item.isHidden = true
//                    item.wantsLayer = true
//                    playerLayer.addSublayer(item.layer!)
                }
        self.firstMLRecognization.isHidden = true
    }
    
}

extension CIImage {

    @objc func savePNG(_ name:String, inDirectoryURL:URL? = nil, quality:CGFloat = 1.0) -> String? {

        var destinationURL = inDirectoryURL

        if destinationURL == nil {
            destinationURL = try? FileManager.default.url(for:.documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }

        if var destinationURL = destinationURL {

            destinationURL = destinationURL.appendingPathComponent(name)

            if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {

                do {

                    let context = CIContext()

                    let pngFormat = CIFormat.RGBA8
                    try context.writePNGRepresentation(of: self, to: destinationURL, format: pngFormat, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption : quality])

//                    try context.writeJPEGRepresentation(of: self, to: destinationURL, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption : quality])

                    return destinationURL.path

                } catch {
                    return nil
                }
            }
        }

        return nil
    }
}

extension NSColor {
    static var random: NSColor {
        return .init(hue: .random(in: 0...1), saturation: 1, brightness: 1, alpha: 1)
    }
}

