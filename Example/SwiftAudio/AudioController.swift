//
//  AudioController.swift
//  SwiftAudio_Example
//
//  Created by Jørgen Henrichsen on 25/03/2018.
//  Copyright © 2018 CocoaPods. All rights reserved.
//

import Foundation
import SwiftAudioEx

class AudioController {
    
    static let shared = AudioController()
    let player: QueuedAudioPlayer
    
    let sources: [AudioItem] = [
        DefaultAudioItem(audioUrl: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3", artist: "SoundHelix", title: "Song 1", sourceType: .stream, artwork: #imageLiteral(resourceName: "22AMI")),
        DefaultAudioItem(audioUrl: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3", artist: "SoundHelix", title: "Song 2", sourceType: .stream, artwork: #imageLiteral(resourceName: "22AMI")),
        DefaultAudioItem(audioUrl: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3", artist: "SoundHelix", title: "Song 3", sourceType: .stream, artwork: #imageLiteral(resourceName: "cover")),
        DefaultAudioItem(audioUrl: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-4.mp3", artist: "SoundHelix", title: "Song 4", sourceType: .stream, artwork: #imageLiteral(resourceName: "22AMI")),
        DefaultAudioItem(audioUrl: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-5.mp3", artist: "SoundHelix", title: "Song 5", sourceType: .stream, artwork: #imageLiteral(resourceName: "22AMI")),
        DefaultAudioItem(audioUrl: "https://ais-sa5.cdnstream1.com/b75154_128mp3", artist: "New York, NY", title: "Smooth Jazz 24/7", sourceType: .stream, artwork: #imageLiteral(resourceName: "cover")),
        DefaultAudioItem(audioUrl: "https://traffic.libsyn.com/atpfm/atp545.mp3", title: "Chapters", sourceType: .stream, artwork: #imageLiteral(resourceName: "22AMI")),
    ]
    
    init() {
        let controller = RemoteCommandController()
        player = QueuedAudioPlayer(remoteCommandController: controller)
        player.event.fail.addListener(self, handlePlayerFailure(error:))
        player.remoteCommands = [
            .stop,
            .play,
            .pause,
            .togglePlayPause,
            .next,
            .previous,
            .changePlaybackPosition
        ]
       
        player.repeatMode = .queue
        DispatchQueue.main.async {
            self.player.add(items: self.sources)
        }
    }

    private func handlePlayerFailure(error: Error?) {
        print("Playback failed for current item. Error: \(String(describing: error))")
        guard !player.nextItems.isEmpty else { return }
        player.next()
    }
}
