.PHONY: all clean

FRAMEWORKS := -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AppKit
CFLAGS := -fobjc-arc -O2

all: thermal

thermal: main.m
	clang $(CFLAGS) $(FRAMEWORKS) -o thermal main.m

clean:
	rm thermal
