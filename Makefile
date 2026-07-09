# Theos Makefile for MyGameCheat
# Install Theos first: https://theos.dev/docs/installation

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyGameCheat

MyGameCheat_FILES = src/main.mm src/MemoryScanner.cpp src/SpeedHack.cpp fishhook/fishhook.c
MyGameCheat_CFLAGS = -fobjc-arc
MyGameCheat_CXXFLAGS = -std=c++17
MyGameCheat_FRAMEWORKS = UIKit WebKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
