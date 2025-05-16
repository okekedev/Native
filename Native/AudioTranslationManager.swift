import Foundation
import AVFoundation
import Speech

class AudioTranslationManager: NSObject, ObservableObject {
    @Published var isTranslating = false {
        didSet {
            if !isTranslating {
                // Use the main queue for state changes to avoid race conditions
                DispatchQueue.main.async { [weak self] in
                    self?.cleanupAudioResources()
                }
            }
        }
    }
    @Published var transcription = ""
    @Published var translatedText = ""
    @Published var isAudioSetupComplete = false
    @Published var errorMessage: String?
    
    // Audio components
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioPlayer: AVSpeechSynthesizer?
    
    // Configuration
    private var translationDelay: TimeInterval = 0.5
    private let bufferSize = 1024
    private let sampleRate = 44100
    
    // Use serial queues for all operations to avoid concurrency issues
    private let audioQueue = DispatchQueue(label: "com.translationbrowser.audio", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "com.translationbrowser.processing", qos: .userInitiated)
    private let synthesisQueue = DispatchQueue(label: "com.translationbrowser.synthesis", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "com.translationbrowser.state", qos: .userInitiated)
    
    // Use a dispatch queue for synchronization instead of locks
    private let syncQueue = DispatchQueue(label: "com.translationbrowser.sync", qos: .userInteractive)
    
    // State management
    private var isAudioSessionActive = false
    private var shouldStopProcessing = false
    private var isTapInstalled = false
    
    // Define TranslationState as a public enum that conforms to Equatable
    enum TranslationState: Equatable {
        case idle
        case preparing
        case translating
        case stopped
        case error(String)
        
        // Implement Equatable for the error case
        static func == (lhs: TranslationState, rhs: TranslationState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.preparing, .preparing),
                 (.translating, .translating),
                 (.stopped, .stopped):
                return true
            case (.error(let lhsMsg), .error(let rhsMsg)):
                return lhsMsg == rhsMsg
            default:
                return false
            }
        }
    }
    
    // Use private(set) to allow reading but not writing from outside
    @Published private(set) var state: TranslationState = .idle {
        didSet {
            if state == .stopped {
                DispatchQueue.main.async { [weak self] in
                    self?.cleanupAudioResources()
                }
            }
        }
    }
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        // Execute on a background thread to avoid blocking the main thread
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, 
                                     mode: .spokenAudio,
                                     options: [.defaultToSpeaker, .allowBluetooth])
                try session.setPreferredSampleRate(Double(self.sampleRate))
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                
                // Update state safely
                self.syncQueue.sync {
                    self.isAudioSessionActive = true
                }
                
                self.requestPermissions()
            } catch {
                self.handleError(error)
            }
        }
    }
    
    private func requestPermissions() {
        // First request microphone permission
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                if granted {
                    self?.requestSpeechRecognitionPermission()
                } else {
                    self?.handleError(NSError(domain: "AudioTranslation",
                                           code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"]))
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                if granted {
                    self?.requestSpeechRecognitionPermission()
                } else {
                    self?.handleError(NSError(domain: "AudioTranslation",
                                           code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"]))
                }
            }
        }
    }
    
    private func requestSpeechRecognitionPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            switch status {
            case .authorized:
                self?.audioQueue.async {
                    self?.setupAudioEngine()
                }
            case .denied:
                self?.handleError("Speech recognition permission denied")
            case .restricted:
                self?.handleError("Speech recognition is restricted")
            case .notDetermined:
                self?.handleError("Speech recognition not determined")
            @unknown default:
                self?.handleError("Unknown speech recognition status")
            }
        }
    }
    
    private func setupAudioEngine() {
        // Ensure we're not already in setup
        let canProceed = syncQueue.sync { () -> Bool in
            guard audioEngine == nil else { return false }
            return true
        }
        
        guard canProceed else { return }
        
        // Create new instances outside the sync block
        let newEngine = AVAudioEngine()
        let newRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let newPlayer = AVSpeechSynthesizer()
        
        guard let recognizer = newRecognizer,
              recognizer.isAvailable else {
            handleError("Speech recognition is not available")
            return
        }
        
        // Update state
        DispatchQueue.main.async { [weak self] in
            self?.state = .preparing
        }
        
        // Configure audio engine
        do {
            let inputNode = newEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            // Configure recognition request
            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.shouldReportPartialResults = true
            
            // Prepare engine
            try newEngine.start()
            
            // Install tap
            inputNode.installTap(onBus: 0,
                               bufferSize: AVAudioFrameCount(bufferSize),
                               format: recordingFormat) { [weak self] buffer, time in
                guard let self = self else { return }
                
                var shouldProcess = false
                self.syncQueue.sync {
                    shouldProcess = !self.shouldStopProcessing && self.isTranslating
                }
                
                if shouldProcess {
                    self.processAudioBuffer(buffer, time: time)
                }
            }
            
            // If we got here, setup was successful - update state atomically
            syncQueue.sync {
                audioEngine = newEngine
                speechRecognizer = recognizer
                audioPlayer = newPlayer
                recognitionRequest = newRequest
                isTapInstalled = true
                
                // Start recognition task
                recognitionTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
                    guard let self = self else { return }
                    
                    if let error = error {
                        // Only handle error if we're still translating
                        self.syncQueue.sync {
                            if !self.shouldStopProcessing && self.isTranslating {
                                self.handleError(error)
                            }
                        }
                        return
                    }
                    
                    if let result = result {
                        DispatchQueue.main.async {
                            self.transcription = result.bestTranscription.formattedString
                            self.processTranscription(result.bestTranscription.formattedString)
                        }
                    }
                }
            }
            
            // Update UI state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isAudioSetupComplete = true
                self.state = .idle
            }
            
        } catch {
            handleError("Failed to setup audio engine: \(error.localizedDescription)")
            
            // Cleanup on error
            syncQueue.sync {
                cleanupAudioEngineResources()
            }
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Run on the processing queue to avoid blocking the audio thread
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if we should continue processing
            var shouldProcess = false
            self.syncQueue.sync {
                shouldProcess = !self.shouldStopProcessing && self.isTranslating
            }
            
            guard shouldProcess,
                  let channelData = buffer.floatChannelData,
                  buffer.frameLength > 0,
                  buffer.format.channelCount > 0 else { return }
            
            // Safely access the first channel
            let channel = 0
            guard channel < buffer.format.channelCount else { return }
            
            // Create a safe copy of the audio data
            let frameCount = Int(buffer.frameLength)
            let audioData = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
            let processedData = Array(audioData)
            
            // Process in smaller chunks with additional safety checks
            let chunkSize = min(256, frameCount)
            for offset in stride(from: 0, to: frameCount, by: chunkSize) {
                // Check again if we should continue processing
                self.syncQueue.sync {
                    shouldProcess = !self.shouldStopProcessing && self.isTranslating
                }
                
                if !shouldProcess { break }
                
                let size = min(chunkSize, frameCount - offset)
                guard offset + size <= processedData.count else { break }
                
                let chunk = Array(processedData[offset..<offset+size])
                
                // Process this chunk
                self.processAudioChunk(chunk)
            }
        }
    }
    
    private func processAudioChunk(_ chunk: [Float]) {
        // Audio processing can be added here
        // For now, we're just passing through to speech recognition
    }
    
    private func processTranscription(_ text: String) {
        guard !text.isEmpty else { return }
        
        synthesisQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Simulate translation
            let translatedText = "Translated: \(text)"
            
            DispatchQueue.main.async {
                self.translatedText = translatedText
                self.speakTranslatedText(translatedText)
            }
        }
    }
    
    private func speakTranslatedText(_ text: String) {
        var player: AVSpeechSynthesizer?
        
        // Safely access audioPlayer
        syncQueue.sync {
            player = audioPlayer
        }
        
        guard let player = player else { return }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.8
        
        player.speak(utterance)
    }
    
    private func handleError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = error.localizedDescription
            self?.state = .error(error.localizedDescription)
            self?.stopTranslating()
        }
    }
    
    private func handleError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
            self?.state = .error(message)
            self?.stopTranslating()
        }
    }
    
    private func cleanupAudioEngineResources() {
        // First get a snapshot of the current state and resources
        let (engine, task, request) = syncQueue.sync { () -> (AVAudioEngine?, SFSpeechRecognitionTask?, SFSpeechAudioBufferRecognitionRequest?) in
            shouldStopProcessing = true
            let engineCopy = audioEngine
            let taskCopy = recognitionTask
            let requestCopy = recognitionRequest
            
            // Clear references immediately
            audioEngine = nil
            recognitionTask = nil
            recognitionRequest = nil
            
            return (engineCopy, taskCopy, requestCopy)
        }
        
        // Now perform cleanup operations outside the sync block
        if let engine = engine {
            // Remove tap first to prevent any pending callbacks
            if isTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                syncQueue.sync {
                    isTapInstalled = false
                }
            }
            
            // Stop engine if running
            if engine.isRunning {
                engine.stop()
                engine.reset()
            }
        }
        
        // Cleanup speech recognition
        task?.cancel()
        request?.endAudio()
    }
    
    private func cleanupAudioResources() {
        // First, ensure we're not already cleaning up and get current state
        let shouldProceed = syncQueue.sync { () -> Bool in
            if shouldStopProcessing { return false }
            shouldStopProcessing = true
            isTranslating = false
            return true
        }
        
        if !shouldProceed { return }
        
        // Perform cleanup on audioQueue to avoid blocking the main thread
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Cleanup resources
            self.cleanupAudioEngineResources()
            
            // Reset state after cleanup
            self.syncQueue.sync {
                self.shouldStopProcessing = false
                self.isAudioSessionActive = false
            }
            
            // Update UI state
            DispatchQueue.main.async {
                self.isAudioSetupComplete = false
                self.state = .stopped
                self.transcription = ""
                self.translatedText = ""
                self.errorMessage = nil
            }
        }
    }
    
    func startTranslating() {
        // Only process on main thread to avoid race conditions
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.isTranslating { return }
            if !self.isAudioSetupComplete {
                self.handleError("Audio setup not complete")
                return
            }
            
            // Reset processing flag
            self.syncQueue.sync {
                self.shouldStopProcessing = false
            }
            
            // Start audio processing on audio queue
            self.audioQueue.async {
                self.syncQueue.sync {
                    if let engine = self.audioEngine, !engine.isRunning {
                        try? engine.start()
                    }
                }
                
                // Update state on main thread
                DispatchQueue.main.async {
                    self.state = .translating
                    self.isTranslating = true
                }
            }
        }
    }
    
    func stopTranslating() {
        // Only process on main thread to avoid race conditions
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Get current state and update flags atomically
            let wasTranslating = self.syncQueue.sync { () -> Bool in
                if !self.isTranslating { return false }
                self.shouldStopProcessing = true
                self.isTranslating = false
                return true
            }
            
            if !wasTranslating { return }
            
            // Update UI state immediately
            self.state = .idle
            
            // Cleanup resources in background
            self.audioQueue.async {
                self.cleanupAudioResources()
            }
        }
    }
    
    func updateTranslationDelay(_ delay: TimeInterval) {
        syncQueue.async { [weak self] in
            self?.translationDelay = delay
        }
    }
} 
