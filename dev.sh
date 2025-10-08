#!/usr/bin/env bash
set -e
IPHONE_ID=00008120-0004658E1E44C01E
IPAD_ID=479d5cfa5c3aa31be146f2157a8c44241a5235e7
case "$1" in
  iphone)
    flutter clean
    flutter pub get
    cd ios && pod install && cd ..
    flutter run -d "$IPHONE_ID"
    ;;
  ipad)
    flutter clean
    flutter pub get
    cd ios && pod install && cd ..
    flutter run -d "$IPAD_ID"
    ;;
  both)
    flutter clean
    flutter pub get
    cd ios && pod install && cd ..
    flutter run -d "$IPHONE_ID"
    flutter run -d "$IPAD_ID"
    ;;
  *)
    echo "usage: bash dev.sh [iphone|ipad|both]"
    exit 1
    ;;
esac
