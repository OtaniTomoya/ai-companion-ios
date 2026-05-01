//
//  LocationAuthorizationManager.swift
//  chat app
//

import Combine
import CoreLocation
import UIKit

@MainActor
final class LocationAuthorizationManager: NSObject, ObservableObject {
    private static let locationServicesDisabledMessage = "iOSの位置情報サービスが無効です。設定アプリで有効にしてください。"

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var isLocationServicesEnabled: Bool
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var lastErrorMessage: String?

    var onLocationUpdate: ((CLLocation) -> Void)?

    private let locationManager = CLLocationManager()
    private var wantsLocationUpdates = false
    private var hasRequestedWhenInUseAuthorization = false
    private var locationServicesRefreshTask: Task<Void, Never>?

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
        isLocationServicesEnabled = true

        super.init()

        locationManager.delegate = self
        configureForForegroundUpdates()
        refreshAuthorizationState()
    }

    var authorizationSummary: String {
        guard isLocationServicesEnabled else {
            return "位置情報サービスが無効"
        }

        let scope = switch authorizationStatus {
        case .notDetermined:
            "未選択"
        case .restricted:
            "制限あり"
        case .denied:
            "拒否"
        case .authorizedWhenInUse:
            "使用中のみ"
        case .authorizedAlways:
            "常時"
        @unknown default:
            "不明"
        }

        let accuracy = accuracyAuthorization == .fullAccuracy ? "フル精度" : "おおよそ"
        return "\(scope) / \(accuracy)"
    }

    var latestLocationSummary: String {
        guard let latestLocation else {
            return "現在地は未取得"
        }

        let latitude = latestLocation.coordinate.latitude.formatted(.number.precision(.fractionLength(6)))
        let longitude = latestLocation.coordinate.longitude.formatted(.number.precision(.fractionLength(6)))
        let accuracy = latestLocation.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))
        return "\(latitude), \(longitude) / +/-\(accuracy)m"
    }

    func requestForegroundAuthorization() {
        wantsLocationUpdates = true
        continueForegroundAuthorizationFlow()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func continueForegroundAuthorizationFlow() {
        refreshAuthorizationState()
        configureForForegroundUpdates()

        guard isLocationServicesEnabled else {
            lastErrorMessage = Self.locationServicesDisabledMessage
            return
        }

        switch authorizationStatus {
        case .notDetermined:
            guard !hasRequestedWhenInUseAuthorization else { return }
            hasRequestedWhenInUseAuthorization = true
            locationManager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse, .authorizedAlways:
            startForegroundLocationUpdates()
            lastErrorMessage = nil

        case .restricted:
            lastErrorMessage = "位置情報の利用が制限されています。"

        case .denied:
            lastErrorMessage = "位置情報が拒否されています。設定アプリから使用中のみ許可に変更してください。"

        @unknown default:
            lastErrorMessage = "位置情報の許可状態を判定できません。"
        }
    }

    private func configureForForegroundUpdates() {
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100
        locationManager.activityType = .other
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.showsBackgroundLocationIndicator = false
    }

    private func startForegroundLocationUpdates() {
        configureForForegroundUpdates()
        locationManager.startUpdatingLocation()
    }

    private func refreshAuthorizationState() {
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
        refreshLocationServicesAvailability()
    }

    private func refreshLocationServicesAvailability() {
        locationServicesRefreshTask?.cancel()
        locationServicesRefreshTask = Task { [weak self] in
            let isEnabled = await Self.locationServicesEnabledOffMainThread()

            guard !Task.isCancelled, let self else { return }

            let shouldResumeAuthorizationFlow =
                isEnabled && !self.isLocationServicesEnabled && self.wantsLocationUpdates

            self.isLocationServicesEnabled = isEnabled

            if isEnabled {
                if self.lastErrorMessage == Self.locationServicesDisabledMessage {
                    self.lastErrorMessage = nil
                }
            } else {
                self.lastErrorMessage = Self.locationServicesDisabledMessage
            }

            if shouldResumeAuthorizationFlow {
                self.continueForegroundAuthorizationFlow()
            }
        }
    }

    nonisolated private static func locationServicesEnabledOffMainThread() async -> Bool {
        await Task.detached(priority: .utility) {
            CLLocationManager.locationServicesEnabled()
        }.value
    }
}

extension LocationAuthorizationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAuthorizationState()

        guard wantsLocationUpdates else { return }
        continueForegroundAuthorizationFlow()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        latestLocation = location
        lastErrorMessage = nil
        onLocationUpdate?(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastErrorMessage = "位置情報の取得に失敗しました: \(error.localizedDescription)"
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard wantsLocationUpdates else { return }
        startForegroundLocationUpdates()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        lastErrorMessage = nil
    }
}
