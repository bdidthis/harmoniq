set -euo pipefail
export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:$PATH"
export GEM_HOME="$HOME/.gem"
export PATH="$GEM_HOME/bin:$PATH"
DEV="00008120-0004658E1E44C01E"

flutter clean
flutter pub get

cat > ios/Runner/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>HarmoniQ</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>harmoniq_clean_run</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$(FLUTTER_BUILD_NAME)</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>$(FLUTTER_BUILD_NUMBER)</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>UILaunchStoryboardName</key>
	<string>LaunchScreen</string>
	<key>UIMainStoryboardFile</key>
	<string>Main</string>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationPortraitUpsideDown</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>UIViewControllerBasedStatusBarAppearance</key>
	<false/>
	<key>NSMicrophoneUsageDescription</key>
	<string>HarmoniQ needs microphone access to analyze audio</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Flutter needs local network to connect to the debug service.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_dartVmService._tcp</string>
		<string>_dartobservatory._tcp</string>
	</array>
	<key>UIBackgroundModes</key>
	<array>
		<string>audio</string>
		<string>fetch</string>
		<string>processing</string>
	</array>
	<key>LSApplicationQueriesSchemes</key>
	<array>
		<string>fb</string>
		<string>instagram</string>
	</array>
	<key>UIFileSharingEnabled</key>
	<true/>
	<key>LSSupportsOpeningDocumentsInPlace</key>
	<true/>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
	<key>CADisableMinimumFrameDurationOnPhone</key>
	<true/>
</dict>
</plist>
PLIST

mkdir -p ios/Flutter
cat > ios/Flutter/Debug.xcconfig <<'XCD'
#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"
#include "Generated.xcconfig"
XCD
cat > ios/Flutter/Release.xcconfig <<'XCR'
#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig"
#include "Generated.xcconfig"
XCR

cat > ios/Podfile <<'POD'
platform :ios, '15.0'
project 'Runner', { 'Debug' => :debug, 'Profile' => :release, 'Release' => :release }
def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. If you're running pod install manually, make sure flutter pub get is executed first"
  end
  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}. Try deleting Generated.xcconfig, then run flutter pub get"
end
require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)
flutter_ios_podfile_setup
target "Runner" do
  use_frameworks!
  use_modular_headers!
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
      config.build_settings["ENABLE_BITCODE"] = "NO"
      config.build_settings["EXCLUDED_ARCHS[sdk=iphonesimulator*]"] = "arm64"
      config.build_settings["GCC_PREPROCESSOR_DEFINITIONS"] ||= ["$(inherited)","PERMISSION_MICROPHONE=1"]
    end
  end
  installer.pods_project.build_configurations.each do |config|
    config.build_settings["EXCLUDED_ARCHS[sdk=iphonesimulator*]"] = "arm64"
  end
end
POD

sed -i "" "s/IPHONEOS_DEPLOYMENT_TARGET = .*/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/g" ios/Runner.xcodeproj/project.pbxproj || true
sed -i "" "/:path.*ShareExtension\.appex/d" ios/Runner.xcodeproj/project.pbxproj || true
sed -i "" "/ShareExtension\.appex.*in Embed/d" ios/Runner.xcodeproj/project.pbxproj || true
sed -i "" "/ShareExtension\.appex.*in Copy Files/d" ios/Runner.xcodeproj/project.pbxproj || true

rm -rf ~/Library/Developer/Xcode/DerivedData
rm -rf ios/Pods ios/.symlinks ios/Podfile.lock
( cd ios && pod repo update && pod deintegrate && pod install --repo-update )
flutter run -d "$DEV" --no-wireless --device-timeout 180
