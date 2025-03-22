#!/bin/sh
set -e

# TODO this should not trigger building all targets
zig build run
