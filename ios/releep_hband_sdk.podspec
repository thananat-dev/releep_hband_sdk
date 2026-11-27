#
# releep_hband_sdk — Veepoo / HBand watch SDK bridge for Flutter.
#
# NOTE: the vendored Veepoo frameworks are arm64 *device only* (no simulator
# slice), so the plugin builds and runs on a physical iPhone only.
#
Pod::Spec.new do |s|
  s.name             = 'releep_hband_sdk'
  s.version          = '0.0.3'
  s.summary          = 'Flutter plugin for Veepoo/HBand smartwatches: scan, connect, SOS & fall guard.'
  s.description      = <<-DESC
Flutter plugin for Veepoo/HBand smartwatches: scan, connect, SOS & fall guard.
Wraps VeepooBleSDK 2.2.107.15.
                       DESC
  s.homepage         = 'https://github.com/thananat-dev/releep_hband_sdk'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'thananat-dev' => '82574108+thananat-dev@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,swift}'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.dependency 'FMDB'
  s.dependency 'MJExtension'
  s.platform = :ios, '13.0'

  # Veepoo SDK + chip vendor frameworks (same set the official demo links).
  s.vendored_frameworks = [
    'Frameworks/VeepooBleSDK.framework',
    'Frameworks/JL_BLEKit.framework',
    'Frameworks/DFUnits.framework',
    'Frameworks/JLDialUnit.framework',
    'Frameworks/ZipZap.framework',
    'Frameworks/ABParTool.framework',
    'Frameworks/GRDFUSDK.framework',
  ]
  s.frameworks = 'AVFoundation', 'CallKit', 'CoreBluetooth', 'CoreLocation', 'QuartzCore', 'UIKit', 'UserNotifications'
  s.libraries  = 'z', 'c++', 'sqlite3'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
  }
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) -ObjC' }
  s.swift_version = '5.0'

  s.resource_bundles = { 'releep_hband_sdk_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
