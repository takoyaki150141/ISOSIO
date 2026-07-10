TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = MyGameCheat

# Only main.mm — MemoryScanner / SpeedHack / fishhook removed for the macro tool build.
MyGameCheat_FILES = src/main.mm
MyGameCheat_CFLAGS = -fobjc-arc -Wno-unused-variable
MyGameCheat_CXXFLAGS = -std=c++17
MyGameCheat_OBJCXXFLAGS = -std=c++17
MyGameCheat_LDFLAGS = -Wl,-segalign,4000
MyGameCheat_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/library.mk
