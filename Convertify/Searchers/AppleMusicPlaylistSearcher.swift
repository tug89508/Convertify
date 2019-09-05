//
//  AppleMusicPlaylistSearcher.swift
//  Convertify
//
//  Created by Hayden Hong on 1/24/19.
//  Copyright © 2019 Hayden Hong. All rights reserved.
//

import Alamofire
import Foundation
import StoreKit
import SwiftyJSON

class AppleMusicPlaylistSearcher: PlaylistSearcher {
    var serviceName: String = "Apple Music"

    private let token: String
    private var storefront: String = "us"
    private var playlistID: String?

    init(token: String) {
        self.token = token
    }

    /// Gets the track list from a given playlist
    ///
    /// - Parameters:
    ///   - link: playlist link
    ///   - completion: what to run when the track list is completed
    func getTrackList(link: String, completion: @escaping ([String: String]?, String?, Error?) -> Void) {
        parseLinkData(link: link)

        let headers = ["Authorization": "Bearer \(self.token)"]

        var urlComponents: URLComponents {
            var urlComponents = URLComponents()
            urlComponents.scheme = "https"
            urlComponents.host = "api.music.apple.com"
            urlComponents.path = "/v1/catalog/us/playlists/\(playlistID ?? "")"
            return urlComponents
        }

        guard let url = urlComponents.url else {
            completion(nil, nil, MusicSearcherErrors.invalidLinkFormatError)
            return
        }

        Alamofire.request(url, headers: headers)
            .validate()
            .responseJSON { response in
                switch response.result {
                case .success: do {
                    let data = JSON(response.result.value!)
                    let playlistName = data["data"][0]["attributes"]["name"].stringValue

                    // Gets array of track objects
                    let trackObjects = data["data"][0]["relationships"]["tracks"]["data"].array

                    var trackList: [String: String] = [:]

                    // Adds the tracks to the tracklist
                    for track in trackObjects! {
                        let trackName: String = track["attributes"]["name"].stringValue
                        let artistName: String = track["attributes"]["artistName"].stringValue

                        if trackList[trackName] == nil {
                            trackList[trackName] = artistName
                        } else {
                            print("Duplicate track found: \(trackName)")
                        }
                    }

                    // Run completion with the finished track list
                    completion(trackList, playlistName, nil)
                }

                case let .failure(error): do {
                    completion(nil, nil, error)
                }
                }
            }
    }

    /// Adds a track list to an Apple Music user's playlists as a new playlist
    ///
    /// - Parameters:
    ///   - trackList: list of songs to add to a new playlist
    ///   - completion: what to do when the playlist is added
    func addPlaylist(trackList: [String: String], playlistName: String, completion: @escaping (String?, [String], Error?) -> Void) {
        // Convert the playlist
        getConvertedPlaylist(trackList: trackList, playlistName: playlistName) { playlist, failedTracks in

            // Ensure access to user's Apple Apple Music library
            SKCloudServiceController.requestAuthorization() { authorizationStatus in
                switch authorizationStatus {
                case .authorized: do {
                    // Get Music User Token
                    SKCloudServiceController().requestUserToken(forDeveloperToken: self.token) { musicUserToken, error in

                        let parameters: Parameters = [
                            "attributes": playlist.attributes,
                            "relationships": [
                                "tracks": [
                                    "data": playlist.trackList,
                                ],
                            ],
                        ]

                        let headers: HTTPHeaders = ["Music-User-Token": musicUserToken ?? "", "Authorization": "Bearer \(self.token)"]

                        if error == nil {
                            // Add the playlist to the user's account
                            var urlComponents: URLComponents {
                                var urlComponents = URLComponents()
                                urlComponents.scheme = "https"
                                urlComponents.host = "api.music.apple.com"
                                urlComponents.path = "/v1/me/library/playlists"
                                return urlComponents
                            }

                            guard let url = urlComponents.url else {
                                completion(nil, [], MusicSearcherErrors.invalidLinkFormatError)
                                return
                            }

                            Alamofire.request(url, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: headers)
                                .validate()
                                .responseJSON { response in
                                    switch response.result {
                                    case .success: do {
                                        let data = JSON(response.result.value!)
                                        let id = data["data"][0]["id"]
                                        let link = "https://itunes.apple.com/me/playlist/\(playlistName.replacingOccurrences(of: " ", with: "-").lowercased())/\(id)"
                                        completion(link, failedTracks, nil)
                                    }
                                    case let .failure(error): do {
                                        completion(nil, failedTracks, error)
                                    }
                                    }
                                }
                        } else {
                            completion(nil, failedTracks, error)
                        }
                    }
                }

                // We can't do anything without the user agreeing, so we just prompt again
                default: do {
                    completion(nil, [], MusicSearcherErrors.notAuthorizedError)
                }
                }
            }
        }
    }

    /// Convert the playlist from the [Song: Artist] list to an array of AppleMusicPlaylistItems
    ///
    /// - Parameters:
    ///   - trackList: list of [Song: Artist], probably from Spotify
    ///   - completion: what to do with the completed playlist with IDs
    private func getConvertedPlaylist(trackList: [String: String], playlistName: String,
                                      completion: @escaping (AppleMusicPlaylist, [String]) -> Void) {
        let appleMusic: MusicSearcher = AppleMusicSearcher(token: token)

        getConvertedPlaylistHelper(trackList: trackList,
                                   playlist: AppleMusicPlaylist(playlistName: playlistName),
                                   failedTracks: [],
                                   appleMusic: appleMusic) { playlist, failedTracks in
            completion(playlist, failedTracks)
        }
    }

    /// Recursive helper for making the tracklist
    ///
    /// - Parameters:
    ///   - trackList: list of [song: artist]
    ///   - playlist: playlist to be added to
    ///   - failedTracks: list of failed tracks for adding
    ///   - appleMusic: apple music searcher
    ///   - completion: what to run when complete playlist is done
    private func getConvertedPlaylistHelper(trackList: [String: String],
                                            playlist: AppleMusicPlaylist,
                                            failedTracks: [String],
                                            appleMusic: MusicSearcher,
                                            completion: @escaping (AppleMusicPlaylist, [String]) -> Void) {
        // Base case, stop adding to the playlist if the tracklist is empty
        if trackList.isEmpty {
            completion(playlist, failedTracks)
            return
        }

        // Get the current track with a mutable temp track list
        var trackList = trackList
        var failedTracks = failedTracks
        let currentTrack = trackList.popFirst()

        // Search for the ID of the song
        appleMusic.search(name: "\(currentTrack?.key ?? "") \(currentTrack?.value ?? "")", type: "song") { link, error in
            var playlist = playlist

            // Report errors or add to the current playlist
            if error != nil {
                print("Had trouble finding \(currentTrack?.key ?? "") by \(currentTrack?.value ?? "")")
                failedTracks.append("\(currentTrack?.key ?? "") by \(currentTrack?.value ?? "") ")
            } else {
                let id = String(link!.components(separatedBy: "?i=")[1])
                playlist.addTrack(id: id)
            }

            // Recursively keep searching
            self.getConvertedPlaylistHelper(trackList: trackList,
                                            playlist: playlist,
                                            failedTracks: failedTracks,
                                            appleMusic: appleMusic,
                                            completion: completion)
        }
    }

    /// Parses Apple Music link data
    ///
    /// - Parameter link: Apple Music link to parse from
    private func parseLinkData(link: String) {
        playlistID = String(link.components(separatedBy: "/playlist/")[1]
            .split(separator: "/")[1])

        if link.contains("itunes.apple.com") {
            storefront = String(link.components(separatedBy: "https://itunes.apple.com/")[1]
                .split(separator: "/")[0])
        } else if link.contains("music.apple.com") {
            storefront = String(link.components(separatedBy: "https://music.apple.com/")[1]
                .split(separator: "/")[0])
        }
    }
}

/// Framework of an Apple Music Playlist
private struct AppleMusicPlaylist {
    var trackList: [[String: String]]
    var attributes: [String: String]

    init(playlistName: String?) {
        trackList = []
        attributes = ["name": playlistName ?? "New Playlist",
                      "description": "Created with Convertify for iOS, some songs might not be correct"]
    }

    mutating func addTrack(id: String) {
        trackList.append(["id": id, "type": "songs"])
    }
}
