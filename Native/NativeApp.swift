//
//  NativeApp.swift
//  Native
//
//  Created by Christian Okeke on 5/16/25.
//

import SwiftUI

@main
struct NativeApp: App {
    @StateObject private var translationManager = AudioTranslationManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(translationManager)
        }
    }
}
