TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyGameCheat

MyGameCheat_FILES = src/main.mm src/MemoryScanner.cpp src/SpeedHack.cpp
MyGameCheat_CFLAGS = -fobjc-arc -std=c++17
MyGameCheat_LDFLAGS = -Wl,-segalign,4000
MyGameCheat_FRAMEWORKS = UIKit WebKit
MyGameCheat_LIBRARIES = fishhook

include $(THEOS_MAKE_PATH)/tweak.mk