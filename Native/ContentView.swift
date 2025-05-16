//
//  ContentView.swift
//  Native
//
//  Created by Christian Okeke on 5/16/25.
//

import SwiftUI
import WebKit
import Speech
import AVFoundation

struct WebView: UIViewRepresentable {
    @Binding var url: URL
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    var webView: WKWebView
    
    init(url: Binding<URL>, canGoBack: Binding<Bool>, canGoForward: Binding<Bool>) {
        self._url = url
        self._canGoBack = canGoBack
        self._canGoForward = canGoForward
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        self.webView = WKWebView(frame: .zero, configuration: configuration)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        
        init(_ parent: WebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var translationManager: AudioTranslationManager
    @State private var currentURL = URL(string: "https://www.google.com")!
    @State private var urlString = "https://www.google.com"
    @State private var isShowingSettings = false
    @State private var favorites: [URL] = []
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var showTranscription = true
    @State private var showError = false
    
    private let webView = WKWebView()
    
    var body: some View {
        VStack(spacing: 0) {
            // Navigation Bar
            HStack(spacing: 8) {
                Button(action: { webView.goBack() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(canGoBack ? .blue : .gray)
                }
                .disabled(!canGoBack)
                
                Button(action: { webView.goForward() }) {
                    Image(systemName: "chevron.right")
                        .foregroundColor(canGoForward ? .blue : .gray)
                }
                .disabled(!canGoForward)
                
                TextField("Enter URL", text: $urlString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    .onSubmit {
                        if let url = URL(string: urlString) {
                            currentURL = url
                        }
                    }
                
                Button(action: { webView.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                
                Button(action: { isShowingSettings.toggle() }) {
                    Image(systemName: "gear")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Browser View
            WebView(url: $currentURL, canGoBack: $canGoBack, canGoForward: $canGoForward)
                .overlay(
                    VStack {
                        if let error = translationManager.errorMessage {
                            Text(error)
                                .font(.caption)
                                .padding(8)
                                .background(Color.red.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                                .padding()
                                .transition(.opacity)
                                .onAppear {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                        translationManager.errorMessage = nil
                                    }
                                }
                        }
                        
                        if showTranscription && translationManager.isTranslating {
                            VStack(spacing: 4) {
                                Text(translationManager.transcription)
                                    .font(.caption)
                                    .padding(8)
                                    .background(Color.black.opacity(0.7))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                
                                Text(translationManager.translatedText)
                                    .font(.caption)
                                    .padding(8)
                                    .background(Color.blue.opacity(0.7))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .padding()
                            .transition(.opacity)
                        }
                        
                        Spacer()
                        
                        HStack {
                            Spacer()
                            Button(action: {
                                if translationManager.isTranslating {
                                    translationManager.stopTranslating()
                                } else {
                                    translationManager.startTranslating()
                                }
                            }) {
                                Image(systemName: translationManager.isTranslating ? "waveform.circle.fill" : "waveform.circle")
                                    .font(.system(size: 44))
                                    .foregroundColor(translationManager.isAudioSetupComplete ? .blue : .gray)
                                    .background(Color.white.opacity(0.8))
                                    .clipShape(Circle())
                                    .shadow(radius: 4)
                            }
                            .disabled(!translationManager.isAudioSetupComplete)
                            .padding()
                        }
                    }
                )
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(showTranscription: $showTranscription)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var translationManager: AudioTranslationManager
    @Binding var showTranscription: Bool
    @State private var sourceLanguage = "English"
    @State private var targetLanguage = "Spanish"
    @State private var originalVolume: Double = 0.3
    @State private var translationVolume: Double = 0.7
    @State private var translationDelay: Double = 0.5
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Languages")) {
                    Picker("Source Language", selection: $sourceLanguage) {
                        Text("English").tag("English")
                        Text("Spanish").tag("Spanish")
                        Text("French").tag("French")
                        // Add more languages
                    }
                    
                    Picker("Target Language", selection: $targetLanguage) {
                        Text("Spanish").tag("Spanish")
                        Text("English").tag("English")
                        Text("French").tag("French")
                        // Add more languages
                    }
                }
                
                Section(header: Text("Audio")) {
                    VStack {
                        Text("Original Audio Volume")
                        Slider(value: $originalVolume)
                    }
                    
                    VStack {
                        Text("Translation Volume")
                        Slider(value: $translationVolume)
                    }
                }
                
                Section(header: Text("Translation")) {
                    VStack {
                        Text("Translation Delay: \(String(format: "%.1f", translationDelay))s")
                        Slider(value: $translationDelay, in: 0.1...2.0)
                            .onChange(of: translationDelay, initial: true) { oldValue, newValue in
                                translationManager.updateTranslationDelay(newValue)
                            }
                    }
                    
                    Toggle("Show Transcription", isOn: $showTranscription)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AudioTranslationManager())
    }
}
