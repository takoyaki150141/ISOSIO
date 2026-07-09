TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyGameCheat

MyGameCheat_FILES = src/main.mm src/MemoryScanner.cpp src/SpeedHack.cpp fishhook/fishhook.c
MyGameCheat_CFLAGS = -fobjc-arc
MyGameCheat_LDFLAGS = -Wl,-segalign,4000
MyGameCheat_FRAMEWORKS = UIKit WebKit

include $(THEOS_MAKE_PATH)/tweak.mk