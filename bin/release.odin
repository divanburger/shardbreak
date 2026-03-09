#!/bin/sh
//usr/bin/env -S /home/divan/git/odin/odin run "$0" -file -- ; exit
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

GAME_NAME :: "shardbreak"
BUILD_DIR :: "build"
GAME_DIR :: BUILD_DIR + "/" + GAME_NAME
OUT_BIN :: GAME_DIR + "/" + GAME_NAME

ODIN :: "/home/divan/git/odin/odin"

ASSETS :: []string{
	"assets/blocks.json",
	"assets/images.json",
	"assets/fonts/Kenney_Future.ttf",
	"assets/ui/button_square.png",
	"assets/ui/button_square_depth.png",
	"assets/ui/button_square_header_blade_square_screws.png",
	"assets/ui/panel_square.png",
	"assets/patterns/pattern_07.png",
	"levels/level_1.json",
	"levels/level_2.json",
	"levels/level_3.json",
	"levels/level_4.json",
}

ARCHIVE_NAME :: GAME_NAME + ".tar.gz"
ARCHIVE_PATH :: BUILD_DIR + "/" + ARCHIVE_NAME

main :: proc() {
	ok := release()
	if !ok {
		os.exit(1)
	}
}

release :: proc() -> bool {
	// Clean build dir
	if os.exists(BUILD_DIR) {
		fmt.println("Cleaning build directory...")
		err := os.remove_all(BUILD_DIR)
		if err != nil {
			fmt.eprintln("Failed to remove build directory:", err)
			return false
		}
	}

	// Create game dir
	{
		err := os.make_directory_all(GAME_DIR)
		if err != nil {
			fmt.eprintln("Failed to create game directory:", err)
			return false
		}
	}

	// Build binary
	fmt.println("Building binary...")
	{
		state, _, stderr, err := os.process_exec(
			{command = {ODIN, "build", ".", "-o:speed", "-out:" + OUT_BIN}},
			context.allocator,
		)
		if err != nil {
			fmt.eprintln("Failed to start build:", err)
			return false
		}
		if state.exit_code != 0 {
			fmt.eprintln("Build failed (exit code", state.exit_code, ")")
			fmt.eprint(string(stderr))
			return false
		}
	}
	fmt.println("Build OK")

	// Copy assets
	fmt.println("Copying assets...")
	for asset in ASSETS {
		dst := fmt.tprintf("%s/%s", GAME_DIR, asset)
		dst_dir := filepath.dir(dst, context.temp_allocator)
		os.make_directory_all(dst_dir)

		data, read_err := os.read_entire_file(asset, context.temp_allocator)
		if read_err != nil {
			fmt.eprintln("Failed to read:", asset, read_err)
			return false
		}

		write_err := os.write_entire_file(dst, data)
		if write_err != nil {
			fmt.eprintln("Failed to write:", dst, write_err)
			return false
		}
	}
	fmt.println("Copied", len(ASSETS), "files")

	// Create archive
	fmt.println("Creating archive...")
	{
		state, _, stderr, err := os.process_exec(
			{
				command = {"tar", "czf", ARCHIVE_NAME, GAME_NAME + "/"},
				working_dir = BUILD_DIR,
			},
			context.allocator,
		)
		if err != nil {
			fmt.eprintln("Failed to start tar:", err)
			return false
		}
		if state.exit_code != 0 {
			fmt.eprintln("tar failed (exit code", state.exit_code, ")")
			fmt.eprint(string(stderr))
			return false
		}
	}

	// Report
	info, stat_err := os.stat(ARCHIVE_PATH, context.temp_allocator)
	if stat_err != nil {
		fmt.eprintln("Failed to stat zip:", stat_err)
		return false
	}
	size_mb := f64(info.size) / (1024 * 1024)
	fmt.printf("Created %s (%.1f MB)\n", ARCHIVE_PATH, size_mb)
	return true
}
