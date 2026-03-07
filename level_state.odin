package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

Ball :: struct {
	using circle: Circle,
	vel: vec2,
}

Paddle :: struct {
	pos: vec2,
}

Block :: struct {
	lives: int,
}

Level :: struct {
	blocks:       [BLOCK_COLS * BLOCK_ROWS]Block,
	playing_area: Rect,
}

LevelState :: struct {
	using level: Level,
	ball:   Ball,
	paddle: Paddle,
	score:  int,
}

RunState :: struct {
	lives:     int,
	level_idx: int,
}

LevelFile :: struct {
	blocks:              [dynamic][dynamic]int,
	playing_area_width:  f32,
}

level_load :: proc(path: string) -> (level: Level, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return }
	defer delete(data)

	file: LevelFile
	if json.unmarshal(data, &file) != nil {
		fmt.eprintln("level_load: could not parse", path)
		return
	}
	defer {
		for row in file.blocks { delete(row) }
		delete(file.blocks)
	}

	for row, r in file.blocks {
		if r >= BLOCK_ROWS { break }
		for lives, c in row {
			if c >= BLOCK_COLS { break }
			level.blocks[r * BLOCK_COLS + c].lives = lives
		}
	}

	w := file.playing_area_width if file.playing_area_width > 0 else GAME_SIZE.x
	half := w / 2
	cx   := GAME_SIZE.x / 2
	level.playing_area = Rect{min = {cx - half, BLOCK_AREA_Y}, max = {cx + half, GAME_SIZE.y}}
	return level, true
}

level_state_init :: proc(s: ^LevelState, level: Level) {
	s^ = {}
	s.level  = level
	s.paddle = {pos = {GAME_SIZE.x / 2, PADDLE_Y}}
	s.ball   = {circle = {pos = {s.paddle.pos.x, s.paddle.pos.y - PADDLE_SIZE.y/2 - BALL_RADIUS - 5}, radius = BALL_RADIUS}, vel = {BALL_SPEED.x, -abs(BALL_SPEED.y)}}
}

run_state_init :: proc(run: ^RunState, ls: ^LevelState, levels: []Level) {
	run.lives     = STARTING_LIVES
	run.level_idx = 0
	level_state_init(ls, levels[0])
}

levels_load :: proc(allocator := context.allocator) -> (levels: []Level, ok: bool) {
	result := make([dynamic]Level, allocator)
	for i := 1; ; i += 1 {
		path := fmt.tprintf("levels/level_%d.json", i)
		level, level_ok := level_load(path)
		if !level_ok { break }
		append(&result, level)
	}
	if len(result) == 0 { return nil, false }
	return result[:], true
}
