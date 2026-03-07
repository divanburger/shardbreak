package main

import "core:fmt"
import "core:flags"
import "core:os"
import fp "core:path/filepath"
import glsl "core:math/linalg/glsl"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"
import ef "vendor:stb/easy_font"

WINDOW_TITLE   :: "Shardbreak"
GAME_WIDTH     :: 1280
GAME_HEIGHT    :: 720
GAME_SIZE      :: vec2{GAME_WIDTH, GAME_HEIGHT}
WINDOW_SIZE    :: ivec2{GAME_WIDTH, GAME_HEIGHT}
BALL_RADIUS    :: 36.0
BALL_SPEED     :: vec2{300.0, 216.0}
SEGMENTS       :: 64
VERTEX_COUNT   :: SEGMENTS + 2

PADDLE_SIZE  :: vec2{144.0, 18.0}
PADDLE_SPEED :: 600.0
PADDLE_Y     :: f32(GAME_HEIGHT) - 70.0

BLOCK_COLS   :: 20
BLOCK_ROWS   :: 15
BLOCK_SIZE   :: vec2{57.0, 17.0}
BLOCK_GAP    :: vec2{5.0, 6.0}
BLOCK_AREA_Y :: 50.0

GAME_NAME      :: "Shardbreak"
TEXT_SCALE     :: f32(4)
STARTING_LIVES :: 3

MenuItem    :: enum { StartGame, Options, Quit }
MENU_LABELS :: [MenuItem]string{ .StartGame = "Start game", .Options = "Options", .Quit = "Quit" }

GameScreen  :: enum { MainMenu, Options, Playing, LevelComplete, GameOver }

OptionsItem   :: enum { DisplayMode, Resolution, Back }
OPTION_LABELS :: [OptionsItem]string{ .DisplayMode = "Display Mode", .Resolution = "Resolution", .Back = "Back" }

PauseItem    :: enum { Resume, Quit }
PAUSE_LABELS :: [PauseItem]string{ .Resume = "Resume", .Quit = "Quit" }

PlayingState :: enum { Active, WaitingToStart, Paused }

GameState :: struct {
	running:          bool,
	screen:           GameScreen,
	menu_selected:    MenuItem,
	options_focused:  OptionsItem,
	playing_state:    PlayingState,
	pause_selected:   PauseItem,
	left_held:        bool,
	right_held:       bool,
	should_screenshot: bool,
	dt:               f32,
	elapsed:          f32,
}

block_rect :: proc(col, row: int) -> Rect {
	area_x := (GAME_SIZE.x - (BLOCK_COLS * (BLOCK_SIZE.x + BLOCK_GAP.x) - BLOCK_GAP.x)) / 2
	bmin := vec2{
		area_x + f32(col) * (BLOCK_SIZE.x + BLOCK_GAP.x),
		BLOCK_AREA_Y + f32(row) * (BLOCK_SIZE.y + BLOCK_GAP.y),
	}
	return {min = bmin, max = bmin + BLOCK_SIZE}
}

apply_display_settings :: proc(window: ^SDL.Window, r: ^Renderer, s: Settings) {
	resolutions := RESOLUTIONS
	res := resolutions[s.resolution_idx]
	switch s.display_mode {
	case .Windowed:
		SDL.SetWindowFullscreen(window, false)
		SDL.SetWindowBordered(window, true)
		SDL.SetWindowSize(window, res.x, res.y)
	case .Borderless:
		SDL.SetWindowFullscreen(window, false)
		SDL.SetWindowBordered(window, false)
		SDL.SetWindowSize(window, res.x, res.y)
	case .Fullscreen:
		SDL.SetWindowFullscreen(window, true)
		// Viewport is updated when SDL fires WINDOW_RESIZED
		return
	}
	renderer_set_window_size(r, res)
}

Options :: struct {
	test_script: string `usage:"Path to a test script JSON file to replay."`,
}

handle_main_menu :: proc(event: SDL.Event, gs: ^GameState) {
	#partial switch event.key.scancode {
	case .UP:   gs.menu_selected = MenuItem((int(gs.menu_selected) - 1 + len(MenuItem)) % len(MenuItem))
	case .DOWN: gs.menu_selected = MenuItem((int(gs.menu_selected) + 1) % len(MenuItem))
	case .RETURN, .KP_ENTER:
		switch gs.menu_selected {
		case .StartGame: gs.screen = .Playing; gs.playing_state = .WaitingToStart
		case .Options:   gs.screen = .Options; gs.options_focused = .DisplayMode
		case .Quit:      gs.running = false
		}
	case .ESCAPE: gs.running = false
	}
}

handle_options :: proc(event: SDL.Event, gs: ^GameState, settings: ^Settings, window: ^SDL.Window, r: ^Renderer) {
	#partial switch event.key.scancode {
	case .ESCAPE:
		gs.screen = .MainMenu
	case .UP:
		gs.options_focused = OptionsItem((int(gs.options_focused) - 1 + len(OptionsItem)) % len(OptionsItem))
	case .DOWN:
		gs.options_focused = OptionsItem((int(gs.options_focused) + 1) % len(OptionsItem))
	case .LEFT:
		#partial switch gs.options_focused {
		case .DisplayMode:
			settings.display_mode = DisplayMode((int(settings.display_mode) - 1 + len(DisplayMode)) % len(DisplayMode))
		case .Resolution:
			if settings.display_mode != .Fullscreen {
				settings.resolution_idx = (settings.resolution_idx - 1 + len(RESOLUTIONS)) % len(RESOLUTIONS)
			}
		}
		apply_display_settings(window, r, settings^)
		settings_save(settings^)
	case .RIGHT:
		#partial switch gs.options_focused {
		case .DisplayMode:
			settings.display_mode = DisplayMode((int(settings.display_mode) + 1) % len(DisplayMode))
		case .Resolution:
			if settings.display_mode != .Fullscreen {
				settings.resolution_idx = (settings.resolution_idx + 1) % len(RESOLUTIONS)
			}
		}
		apply_display_settings(window, r, settings^)
		settings_save(settings^)
	case .RETURN, .KP_ENTER:
		if gs.options_focused == .Back { gs.screen = .MainMenu }
	}
}

handle_game_over :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .RETURN, .KP_ENTER, .ESCAPE:
		gs.screen = .MainMenu
		run_state_init(run, state, levels)
		gs.playing_state = .Active
	}
}

handle_level_complete :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .SPACE, .RETURN, .KP_ENTER:
		run.level_idx += 1
		if run.level_idx >= len(levels) {
			gs.screen = .MainMenu
			run_state_init(run, state, levels)
		} else {
			level_state_init(state, levels[run.level_idx])
			gs.screen = .Playing
			gs.playing_state = .WaitingToStart
		}
	case .ESCAPE:
		gs.screen = .MainMenu
		run_state_init(run, state, levels)
	}
}

handle_waiting_to_start :: proc(event: SDL.Event, gs: ^GameState) {
	#partial switch event.key.scancode {
	case .ESCAPE: gs.running = false
	case .SPACE:  gs.playing_state = .Active
	}
}

handle_paused :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .ESCAPE, .PAUSE, .P: gs.playing_state = .Active
	case .UP:   gs.pause_selected = PauseItem((int(gs.pause_selected) - 1 + len(PauseItem)) % len(PauseItem))
	case .DOWN: gs.pause_selected = PauseItem((int(gs.pause_selected) + 1) % len(PauseItem))
	case .RETURN, .KP_ENTER:
		switch gs.pause_selected {
		case .Resume:
			gs.playing_state = .Active
		case .Quit:
			gs.screen = .MainMenu
			run_state_init(run, state, levels)
			gs.playing_state = .Active
		}
	}
}

handle_playing :: proc(event: SDL.Event, gs: ^GameState) {
	#partial switch event.key.scancode {
	case .ESCAPE, .PAUSE, .P: gs.playing_state = .Paused; gs.pause_selected = .Resume
	case .PRINTSCREEN: gs.should_screenshot = true
	case .LEFT:        gs.left_held  = true
	case .RIGHT:       gs.right_held = true
	}
}

handle_event :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level, r: ^Renderer, window: ^SDL.Window, settings: ^Settings) {
	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		gs.running = false
	case .WINDOW_RESIZED:
		renderer_set_window_size(r, {event.window.data1, event.window.data2})
	case .KEY_DOWN:
		switch gs.screen {
		case .MainMenu:      handle_main_menu(event, gs)
		case .Options:       handle_options(event, gs, settings, window, r)
		case .GameOver:      handle_game_over(event, gs, run, state, levels)
		case .LevelComplete: handle_level_complete(event, gs, run, state, levels)
		case .Playing:
			switch gs.playing_state {
			case .WaitingToStart: handle_waiting_to_start(event, gs)
			case .Paused:         handle_paused(event, gs, run, state, levels)
			case .Active:         handle_playing(event, gs)
			}
		}
	case .KEY_UP:
		#partial switch event.key.scancode {
		case .LEFT:  gs.left_held  = false
		case .RIGHT: gs.right_held = false
		}
	}
}

update :: proc(
	gs:       ^GameState,
	opts:     ^Options,
	run:      ^RunState,
	state:    ^LevelState,
	levels:   []Level,
	r:        ^Renderer,
	window:   ^SDL.Window,
	settings: ^Settings,
) {
	event: SDL.Event
	for SDL.PollEvent(&event) {
		handle_event(event, gs, run, state, levels, r, window, settings)
	}

	if gs.screen == .Playing && gs.playing_state == .Active {
		if gs.left_held  { state.paddle.pos.x -= PADDLE_SPEED * gs.dt }
		if gs.right_held { state.paddle.pos.x += PADDLE_SPEED * gs.dt }
		state.paddle.pos.x = clamp(state.paddle.pos.x, state.playing_area.min.x + PADDLE_SIZE.x / 2, state.playing_area.max.x - PADDLE_SIZE.x / 2)

		state.ball.pos += state.ball.vel * gs.dt

		// Block collision
		block_loop: for row in 0..<BLOCK_ROWS {
			for col in 0..<BLOCK_COLS {
				idx := row * BLOCK_COLS + col
				if state.blocks[idx].lives <= 0 { continue }
				rect := block_rect(col, row)
				sep, normal := rect_circle_contact(rect, state.ball.circle)
				if sep <= 0 {
					state.blocks[idx].lives -= 1
					state.score += 100
					state.ball.pos -= sep * normal
					state.ball.vel = glsl.reflect(state.ball.vel, normal)
					break block_loop
				}
			}
		}

		// Level complete check
		all_cleared := true
		for b in state.blocks {
			if b.lives > 0 { all_cleared = false; break }
		}
		if all_cleared { gs.screen = .LevelComplete }

		// Paddle collision
		half_paddle := PADDLE_SIZE / 2
		paddle_rect := Rect{min = state.paddle.pos - half_paddle, max = state.paddle.pos + half_paddle}
		sep, normal := rect_circle_contact(paddle_rect, state.ball.circle)
		if sep <= 0 {
			state.ball.pos -= sep * normal
			if glsl.dot(state.ball.vel, normal) < 0 {
				state.ball.vel = glsl.reflect(state.ball.vel, normal)
			}
		}

		pa := state.playing_area
		if state.ball.pos.x - state.ball.radius < pa.min.x { state.ball.pos.x = pa.min.x + state.ball.radius; state.ball.vel.x =  abs(state.ball.vel.x) }
		if state.ball.pos.x + state.ball.radius > pa.max.x { state.ball.pos.x = pa.max.x - state.ball.radius; state.ball.vel.x = -abs(state.ball.vel.x) }
		if state.ball.pos.y - state.ball.radius < pa.min.y { state.ball.pos.y = pa.min.y + state.ball.radius; state.ball.vel.y =  abs(state.ball.vel.y) }
		if state.ball.pos.y - state.ball.radius > pa.max.y {
			run.lives -= 1
			if run.lives <= 0 {
				gs.screen = .GameOver
			} else {
				state.ball.pos  = {state.paddle.pos.x, state.paddle.pos.y - PADDLE_SIZE.y/2 - state.ball.radius - 5}
				state.ball.vel  = {BALL_SPEED.x, -abs(BALL_SPEED.y)}
				gs.playing_state = .WaitingToStart
			}
		}

		// Keep velocity at constant speed; prevent near-horizontal travel
		speed := glsl.length(BALL_SPEED)
		min_vy := speed * 0.1
		if abs(state.ball.vel.y) < min_vy {
			state.ball.vel.y = min_vy if state.ball.vel.y > 0 else -min_vy
		}
		state.ball.vel = glsl.normalize(state.ball.vel) * speed
	} // end playing_state == .Active

	// Draw calls
	r.clear_color = DARK_GREY if gs.screen == .Playing else BLACK

	if gs.screen != .Playing {
		draw_text(r, GAME_NAME, {GAME_SIZE.x / 2, 10}, TEXT_SCALE, WHITE, .Center)
	}

	if gs.screen == .MainMenu {
		menu_labels := MENU_LABELS
		item_h  := f32(8) * TEXT_SCALE
		spacing := f32(30)
		block_h := f32(len(MenuItem)) * item_h + f32(len(MenuItem) - 1) * spacing
		start_y := (GAME_SIZE.y - block_h) / 2
		for item in MenuItem {
			label  := menu_labels[item]
			color  := YELLOW if item == gs.menu_selected else WHITE
			item_y := start_y + f32(int(item)) * (item_h + spacing)
			draw_text(r, label, {GAME_SIZE.x / 2, item_y}, TEXT_SCALE, color, .Center)
		}
	} else if gs.screen == .Options {
		draw_text(r, "OPTIONS", {GAME_SIZE.x / 2, 80}, TEXT_SCALE, WHITE, .Center)

		resolutions := RESOLUTIONS
		res         := resolutions[settings.resolution_idx]
		values  := [2]string{display_mode_name(settings.display_mode), fmt.tprintf("%dx%d", res.x, res.y)}
		item_h  := f32(8) * TEXT_SCALE
		spacing := f32(30)
		start_y := f32(150)

		option_labels := OPTION_LABELS
		for item in OptionsItem.DisplayMode..=OptionsItem.Resolution {
			fullscreen_res := item == .Resolution && settings.display_mode == .Fullscreen
			color := GREY if fullscreen_res else (YELLOW if item == gs.options_focused else WHITE)
			y     := start_y + f32(int(item)) * (item_h + spacing)
			draw_text(r, option_labels[item], {GAME_SIZE.x * 0.18, y}, TEXT_SCALE, color, .Left)
			draw_text(r, fmt.tprintf("< %s >", values[int(item)]), {GAME_SIZE.x * 0.52, y}, TEXT_SCALE, color, .Left)
		}

		back_color := YELLOW if gs.options_focused == .Back else WHITE
		back_y     := start_y + 2 * (item_h + spacing)
		draw_text(r, option_labels[.Back], {GAME_SIZE.x / 2, back_y}, TEXT_SCALE, back_color, .Center)
	} else if gs.screen == .GameOver {
		draw_text(r, "GAME OVER", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 - 60}, TEXT_SCALE, WHITE, .Center)

		score_str := fmt.tprintf("Score: %d", state.score)
		draw_text(r, score_str, GAME_SIZE / 2, TEXT_SCALE, WHITE, .Center)

		draw_text(r, "Press Enter to return to menu", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 + 60}, TEXT_SCALE, WHITE, .Center)
	} else if gs.screen == .LevelComplete {
		draw_text(r, "LEVEL COMPLETE!", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 - 30}, TEXT_SCALE, YELLOW, .Center)
		draw_text(r, "Press Space to continue", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 + 30}, TEXT_SCALE, WHITE, .Center)
	} else {
		draw_rect(r, state.playing_area, BLACK)

		score_str := fmt.tprintf("Score: %d", state.score)
		draw_text(r, score_str, {GAME_SIZE.x - 10, 10}, TEXT_SCALE, WHITE, .Right)

		draw_text(r, fmt.tprintf("Lives: %d", run.lives), {10, 10}, TEXT_SCALE, WHITE, .Left)
		draw_text(r, fmt.tprintf("Level: %d", run.level_idx + 1), {GAME_SIZE.x / 2, 10}, TEXT_SCALE, WHITE, .Center)

		draw_circle(r, state.ball.circle, WHITE)

		half := PADDLE_SIZE / 2
		draw_rect(r, Rect{min = state.paddle.pos - half, max = state.paddle.pos + half}, WHITE)

		for row in 0..<BLOCK_ROWS {
			for col in 0..<BLOCK_COLS {
				b := state.blocks[row * BLOCK_COLS + col]
				if b.lives <= 0 { continue }
				color := YELLOW if b.lives > 1 else WHITE
				draw_rect(r, block_rect(col, row), color)
			}
		}

		if gs.playing_state == .WaitingToStart {
			draw_rect(r, Rect{min = {}, max = GAME_SIZE}, Color{0, 0, 0, 0.6})
			draw_text(r, "Press space to start", {GAME_SIZE.x / 2, (GAME_SIZE.y - 8 * TEXT_SCALE) / 2}, TEXT_SCALE, WHITE, .Center)
		} else if gs.playing_state == .Paused {
			draw_rect(r, Rect{min = {}, max = GAME_SIZE}, Color{0, 0, 0, 0.6})
			item_h  := f32(8) * TEXT_SCALE
			spacing := f32(30)
			block_h := item_h + f32(1 + len(PauseItem)) * (item_h + spacing)
			start_y := (GAME_SIZE.y - block_h) / 2
			draw_text(r, "PAUSED", {GAME_SIZE.x / 2, start_y}, TEXT_SCALE, WHITE, .Center)
			pause_labels := PAUSE_LABELS
			for item in PauseItem {
				color  := YELLOW if item == gs.pause_selected else WHITE
				item_y := start_y + f32(1 + int(item)) * (item_h + spacing)
				draw_text(r, pause_labels[item], {GAME_SIZE.x / 2, item_y}, TEXT_SCALE, color, .Center)
			}
		}
	}
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix)

	screenshot_dir := "screenshots"
	if opts.test_script != "" {
		screenshot_dir = fmt.aprintf("%s/%s", fp.dir(opts.test_script, context.temp_allocator), fp.stem(opts.test_script))
	}

	if infos, err := os.read_directory_by_path(screenshot_dir, 0, context.allocator); err == nil {
		for fi in infos {
			os.remove(fi.fullpath)
		}
		os.file_info_slice_delete(infos, context.allocator)
	}
	os.make_directory(screenshot_dir)

	if !SDL.Init(SDL.InitFlags{.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", SDL.GetError())
		return
	}
	defer SDL.Quit()

	SDL.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_PROFILE_MASK, 1)
	SDL.GL_SetAttribute(.DOUBLEBUFFER, 1)

	window := SDL.CreateWindow(WINDOW_TITLE, GAME_WIDTH, GAME_HEIGHT, SDL.WindowFlags{.OPENGL})
	if window == nil {
		fmt.eprintln("CreateWindow failed:", SDL.GetError())
		return
	}
	defer SDL.DestroyWindow(window)

	gl_ctx := SDL.GL_CreateContext(window)
	if gl_ctx == nil {
		fmt.eprintln("GL_CreateContext failed:", SDL.GetError())
		return
	}
	defer SDL.GL_DestroyContext(gl_ctx)
	SDL.GL_MakeCurrent(window, gl_ctx)

	GL.load_up_to(3, 3, SDL.gl_set_proc_address)

	r, ok := renderer_init()
	if !ok { return }
	defer renderer_destroy(&r)

	settings := settings_load()

	test_script: TestScript
	if opts.test_script != "" {
		test_script, _ = test_script_load(opts.test_script)
		if s, ok := test_script.settings.?; ok {
			settings = s
		}
	}

	apply_display_settings(window, &r, settings)

	levels, levels_ok := levels_load()
	if !levels_ok { return }
	defer delete(levels)

	state: LevelState
	run: RunState
	run_state_init(&run, &state, levels)

	if idx, ok := test_script.level_idx.?; ok && idx < len(levels) {
		run.level_idx = idx
		level_state_init(&state, levels[idx])
	}

	gs: GameState
	gs.running        = true
	gs.screen         = .MainMenu
	gs.pause_selected = .Resume
	gs.options_focused = .DisplayMode

	prev_counter := SDL.GetPerformanceCounter()
	freq         := SDL.GetPerformanceFrequency()

	for gs.running {
		now          := SDL.GetPerformanceCounter()
		gs.dt         = f32(now - prev_counter) / f32(freq)
		prev_counter  = now
		gs.elapsed   += gs.dt

		free_all(context.temp_allocator)
		test_script_pump(&test_script, gs.elapsed, &gs.should_screenshot, &gs.running)
		renderer_start_frame(&r)
		update(&gs, &opts, &run, &state, levels, &r, window, &settings)
		renderer_end_frame(&r, gs.elapsed, &gs.should_screenshot, window, screenshot_dir)
	}
}
