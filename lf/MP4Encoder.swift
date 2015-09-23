import Foundation
import AVFoundation

protocol MP4EncoderDelegate: class {
    func encoderOnFinishWriting(encoder:MP4Encoder, outputURL:NSURL)
}

final class AVAssetWriterComponent {
    var writer:AVAssetWriter!
    var video:AVAssetWriterInput!
    var audio:AVAssetWriterInput!
    var pixel:AVAssetWriterInputPixelBufferAdaptor!

    init (expectsMediaDataInRealTime:Bool, audioSettings:[String:AnyObject], videoSettings:[String:AnyObject]) {
        do {
            writer = try AVAssetWriter(URL: MP4Encoder.createTemporaryURL(), fileType: AVFileTypeMPEG4)

            audio = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = expectsMediaDataInRealTime
            writer.addInput(audio)
            
            video = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: videoSettings)
            video.expectsMediaDataInRealTime = expectsMediaDataInRealTime
            writer.addInput(video)

            let attributes:[String:AnyObject] = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(unsignedInt: kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: MP4Encoder.defaultWidth,
                kCVPixelBufferHeightKey as String: MP4Encoder.defaultHeight
            ]
            pixel = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: attributes)

            writer.startWriting()
            writer.startSessionAtSourceTime(kCMTimeZero)
        } catch let error as NSError {
            print(error)
        }
    }

    func markAsFinished() {
        audio.markAsFinished()
        video.markAsFinished()
    }
}

final class MP4Encoder:NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, ScreenCaptureOutputPixelBufferDelegate
    {
    static let defaultDuration:Int64 = 2
    static let defaultWidth:NSNumber = 480
    static let defaultHeight:NSNumber = 270
    static let defaultChannels:NSNumber = 1
    static let defaultSampleRate:NSNumber = 44100
    static let defaultAudioBitrate:NSNumber = 32 * 1024
    static let defaultVideoBitrate:NSNumber = 16 * 10 * 1024

    static let defaultAudioSettings:[String:AnyObject] = [
        AVFormatIDKey: NSNumber(unsignedInt: kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey: MP4Encoder.defaultChannels,
        AVEncoderBitRateKey: MP4Encoder.defaultAudioBitrate,
        AVSampleRateKey: MP4Encoder.defaultSampleRate
    ]

    static let defaultVideoSettings:[String:AnyObject] = [
        AVVideoCodecKey: AVVideoCodecH264,
        AVVideoWidthKey: MP4Encoder.defaultWidth,
        AVVideoHeightKey: MP4Encoder.defaultHeight,
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoCompressionPropertiesKey: [
            AVVideoMaxKeyFrameIntervalDurationKey: NSNumber(longLong: MP4Encoder.defaultDuration),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264Baseline30,
            AVVideoAverageBitRateKey: MP4Encoder.defaultVideoBitrate
        ]
    ]

    private static func createTemporaryURL() -> NSURL {
        return NSURL(fileURLWithPath: NSTemporaryDirectory()).URLByAppendingPathComponent(NSUUID().UUIDString + ".mp4")
        
    }

    weak var delegate:MP4EncoderDelegate? = nil
    var duration:Int64 = MP4Encoder.defaultDuration
    var recording:Bool = false
    var expectsMediaDataInRealTime:Bool = true
    var audioSettings:[String:AnyObject] = MP4Encoder.defaultAudioSettings
    var videoSettings:[String:AnyObject] = MP4Encoder.defaultVideoSettings
    let audioQueue:dispatch_queue_t = dispatch_queue_create("com.github.shogo4405.lf.MP4Encoder.audio", DISPATCH_QUEUE_SERIAL)
    let videoQueue:dispatch_queue_t = dispatch_queue_create("com.github.shogo4405.lf.MP4Encoder.video", DISPATCH_QUEUE_SERIAL)

    private var rotateTime:CMTime = kCMTimeZero
    private var component:AVAssetWriterComponent? = nil
    private var components:[NSURL:AVAssetWriterComponent] = [:]
    private let lockQueue:dispatch_queue_t = dispatch_queue_create("com.github.shogo4405.lf.MP4Encoder.lock", DISPATCH_QUEUE_SERIAL)

    override init() {
        super.init()
    }

    func clear() {
        dispatch_sync(lockQueue) {
            self.rotateTime = kCMTimeZero
            self.components.removeAll(keepCapacity: false)
            self.component = nil
        }
    }

    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {

        if (!recording || !CMSampleBufferDataIsReady(sampleBuffer)) {
            return
        }

        let mediaType:String = captureOutput is AVCaptureAudioDataOutput ? AVMediaTypeAudio : AVMediaTypeVideo
        let timestamp:CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if (rotateTime == kCMTimeZero) {
            rotateTime = timestamp
        }

        if (mediaType == AVMediaTypeVideo && rotateTime.value <= timestamp.value) {
            rotateComponent(timestamp, mediaType: mediaType)
        }

        if (component != nil) {
            switch mediaType {
            case AVMediaTypeAudio:
                if (component!.audio.readyForMoreMediaData) {
                    component!.audio.appendSampleBuffer(sampleBuffer)
                }
            case AVMediaTypeVideo:
                if (component!.video.readyForMoreMediaData) {
                    component!.video.appendSampleBuffer(sampleBuffer)
                }
            default:
                break
            }
        }
    }

    func pixelBufferOutput(pixelBuffer:CVPixelBufferRef, timestamp:CMTime) {
        if (!recording) {
            return
        }

        if (rotateTime == kCMTimeZero) {
            rotateTime = timestamp
        }
    
        if (rotateTime.value <= timestamp.value) {
            rotateComponent(timestamp, mediaType: AVMediaTypeVideo)
        }

        if (component!.video.readyForMoreMediaData) {
            component!.pixel.appendPixelBuffer(pixelBuffer, withPresentationTime: timestamp)
        }
    }

    private func rotateComponent(timestamp:CMTime, mediaType:String) {
        dispatch_suspend(mediaType == AVMediaTypeAudio ? videoQueue : audioQueue)
        rotateTime = CMTimeAdd(rotateTime, CMTimeMake(duration * Int64(timestamp.timescale), timestamp.timescale))
        let component:AVAssetWriterComponent? = self.component
        self.component = AVAssetWriterComponent(expectsMediaDataInRealTime: expectsMediaDataInRealTime, audioSettings: audioSettings, videoSettings: videoSettings)
        dispatch_resume(mediaType == AVMediaTypeAudio ? videoQueue : audioQueue)

        if (component != nil) {
            let outputURL:NSURL = component!.writer.outputURL
            components[outputURL] = component
            component!.markAsFinished()
            component!.writer.finishWritingWithCompletionHandler {
                self.onFinishWriting(outputURL)
            }
        }
    }

    private func onFinishWriting(outputURL:NSURL) {
        dispatch_async(lockQueue) {
            self.components.removeValueForKey(outputURL)
            self.delegate?.encoderOnFinishWriting(self , outputURL: outputURL)
            do {
                try NSFileManager.defaultManager().removeItemAtURL(outputURL)
            } catch let error as NSError {
                print(error)
            }
        }
    }
}
