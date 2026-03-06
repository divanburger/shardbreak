package main

import "core:fmt"
import "core:flags"
import "core:os"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"
import ef "vendor:stb/easy_font"

WINDOW_TITLE   :: "Shardbreak"
WINDOW_WIDTH   :: 1280
WINDOW_HEIGHT  :: 720
WINDOW_SIZE    :: ivec2{WINDOW_WIDTH, WINDOW_HEIGHT}
BALL_RADIUS    :: 36.0
BALL_SPEED     :: vec2{300.0, 216.0}
SEGMENTS       :: 64
VERTEX_COUNT   :: SEGMENTS + 2

PADDLE_SIZE  :: vec2{144.0, 18.0}
PADDLE_SPEED :: 600.0
PADDLE_Y     :: f32(WINDOW_HEIGHT) - 70.0

BLOCK_COLS   :: 20
BLOCK_ROWS   :: 5
BLOCK_SIZE   :: vec2{57.0, 17.0}
BLOCK_GAP    :: vec2{5.0, 6.0}
BLOCK_AREA_Y :: 50.0

GAME_NAME      :: "Shardbreak"
TEXT_SCALE     :: f32(4)
STARTING_LIVES :: 3

GameScreen  :: enum { MainMenu, Options, Playing, GameOver }
OptionsItem :: enum { DisplayMode, Resolution, Back }

block_rect :: proc(col, row: int) -> Rect {
	area_x := (f32(WINDOW_WIDTH) - (BLOCK_COLS * (BLOCK_SIZE.x + BLOCK_GAP.x) - BLOCK_GAP.x)) / 2
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

update :: proc(
	prev_counter:       ^u64,
	freq:                u64,
	running:            ^bool,
	screen:             ^GameScreen,
	menu_selected:      ^int,
	waiting_to_start:   ^bool,
	paused:             ^bool,
	opts:               ^Options,
	left_held:          ^bool,
	right_held:         ^bool,
	state:              ^LevelState,
	elapsed:            ^f32,
	should_screenshot:  ^bool,
	r:                  ^Renderer,
	window:             ^SDL.Window,
	settings:           ^Settings,
	options_focused:    ^OptionsItem,
) {
	now := SDL.GetPerformanceCounter()
	dt  := f32(now - prev_counter^) / f32(freq)
	prev_counter^ = now

	event: SDL.Event
	for SDL.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			running^ = false
		case .WINDOW_RESIZED:
			renderer_set_window_size(r, {event.window.data1, event.window.data2})
		case .KEY_DOWN:
			if screen^ == .MainMenu {
				menu_items := []string{"Start game", "Options", "Quit"}
				#partial switch event.key.scancode {
				case .UP:   menu_selected^ = (menu_selected^ - 1 + len(menu_items)) % len(menu_items)
				case .DOWN: menu_selected^ = (menu_selected^ + 1) % len(menu_items)
				case .RETURN, .KP_ENTER:
					switch menu_selected^ {
					case 0: screen^ = .Playing; waiting_to_start^ = true
					case 1: screen^ = .Options; options_focused^ = .DisplayMode
					case 2: running^ = false
					}
				case .ESCAPE: running^ = false
				}
			} else if screen^ == .Options {
				#partial switch event.key.scancode {
				case .ESCAPE:
					screen^ = .MainMenu
				case .UP:
					options_focused^ = OptionsItem((int(options_focused^) - 1 + len(OptionsItem)) % len(OptionsItem))
				case .DOWN:
					options_focused^ = OptionsItem((int(options_focused^) + 1) % len(OptionsItem))
				case .LEFT:
					#partial switch options_focused^ {
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
					#partial switch options_focused^ {
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
					if options_focused^ == .Back { screen^ = .MainMenu }
				}
			} else if screen^ == .GameOver {
				#partial switch event.key.scancode {
				case .RETURN, .KP_ENTER, .ESCAPE:
					screen^ = .MainMenu
					state^ = LevelState{
						ball   = {circle = {pos = {WINDOW_WIDTH / 2.0, WINDOW_HEIGHT / 2.0}, radius = BALL_RADIUS}, vel = BALL_SPEED},
						paddle = {pos = {f32(WINDOW_WIDTH) / 2.0, PADDLE_Y}},
						lives  = STARTING_LIVES,
					}
					for &b in state.blocks { b = true }
					waiting_to_start^ = false
					paused^ = false
				}
			} else if waiting_to_start^ {
				#partial switch event.key.scancode {
				case .ESCAPE: running^ = false
				case:         waiting_to_start^ = false
				}
			} else {
				#partial switch event.key.scancode {
				case .ESCAPE:      running^ = false
				case .PAUSE, .P:   paused^ = !paused^
				case .PRINTSCREEN: should_screenshot^ = true
				case .LEFT:        left_held^  = true
				case .RIGHT:       right_held^ = true
				}
			}
		case .KEY_UP:
			#partial switch event.key.scancode {
			case .LEFT:  left_held^  = false
			case .RIGHT: right_held^ = false
			}
		}
	}

	elapsed^ += dt

if screen^ == .Playing && !paused^ && !waiting_to_start^ {
		if left_held^  { state.paddle.pos.x -= PADDLE_SPEED * dt }
		if right_held^ { state.paddle.pos.x += PADDLE_SPEED * dt }
		state.paddle.pos.x = clamp(state.paddle.pos.x, PADDLE_SIZE.x / 2, f32(WINDOW_WIDTH) - PADDLE_SIZE.x / 2)

		state.ball.pos += state.ball.vel * dt

		// Block collision
		block_loop: for row in 0..<BLOCK_ROWS {
			for col in 0..<BLOCK_COLS {
				idx := row * BLOCK_COLS + col
				if !state.blocks[idx] { continue }
				rect := block_rect(col, row)
				if rect_circle_dist(rect, state.ball.circle) <= 0 {
					state.blocks[idx] = false
					state.score += 100
					if state.ball.pos.x >= rect.min.x && state.ball.pos.x <= rect.max.x {
						state.ball.vel.y = -state.ball.vel.y
					} else {
						state.ball.vel.x = -state.ball.vel.x
					}
					break block_loop
				}
			}
		}

		// Paddle collision: ball bottom hits paddle top
		half_paddle := PADDLE_SIZE / 2
		paddle_rect := Rect{min = state.paddle.pos - half_paddle, max = state.paddle.pos + half_paddle}
		if state.ball.vel.y > 0 && rect_circle_dist(paddle_rect, state.ball.circle) <= 0 {
			state.ball.pos.y = paddle_rect.min.y - state.ball.radius
			state.ball.vel.y = -abs(state.ball.vel.y)
		}

		if state.ball.pos.x - state.ball.radius < 0            { state.ball.pos.x = state.ball.radius;                state.ball.vel.x =  abs(state.ball.vel.x) }
		if state.ball.pos.x + state.ball.radius > WINDOW_WIDTH { state.ball.pos.x = WINDOW_WIDTH - state.ball.radius; state.ball.vel.x = -abs(state.ball.vel.x) }
		if state.ball.pos.y - state.ball.radius < 0            { state.ball.pos.y = state.ball.radius;                state.ball.vel.y =  abs(state.ball.vel.y) }
		if state.ball.pos.y - state.ball.radius > WINDOW_HEIGHT {
			state.lives -= 1
			if state.lives <= 0 {
				screen^ = .GameOver
			} else {
				state.ball.pos  = {state.paddle.pos.x, state.paddle.pos.y - PADDLE_SIZE.y/2 - state.ball.radius - 5}
				state.ball.vel  = {BALL_SPEED.x, -abs(BALL_SPEED.y)}
				waiting_to_start^ = true
			}
		}
	} // end !paused

	// Draw calls
	text_w    := f32(ef.width(GAME_NAME)) * TEXT_SCALE
	title_pos := vec2{(f32(WINDOW_WIDTH) - text_w) / 2, 10}
	draw_text(r, GAME_NAME, title_pos, TEXT_SCALE, WHITE)

	if screen^ == .MainMenu {
		menu_items := []string{"Start game", "Options", "Quit"}
		item_h     := f32(8) * TEXT_SCALE
		spacing    := f32(30)
		block_h    := f32(len(menu_items)) * item_h + f32(len(menu_items) - 1) * spacing
		start_y    := (f32(WINDOW_HEIGHT) - block_h) / 2
		for item, i in menu_items {
			color  := WHITE if i != menu_selected^ else YELLOW
			item_w := f32(ef.width(item)) * TEXT_SCALE
			item_x := (f32(WINDOW_WIDTH) - item_w) / 2
			item_y := start_y + f32(i) * (item_h + spacing)
			draw_text(r, item, vec2{item_x, item_y}, TEXT_SCALE, color)
		}
	} else if screen^ == .Options {
		opts_title := "OPTIONS"
		opts_w     := f32(ef.width(opts_title)) * TEXT_SCALE
		draw_text(r, opts_title, {(f32(WINDOW_WIDTH) - opts_w) / 2, 80}, TEXT_SCALE, WHITE)

		resolutions := RESOLUTIONS
		res         := resolutions[settings.resolution_idx]
		labels  := [2]string{"Display Mode", "Resolution"}
		values  := [2]string{display_mode_name(settings.display_mode), fmt.tprintf("%dx%d", res.x, res.y)}
		item_h  := f32(8) * TEXT_SCALE
		spacing := f32(30)
		start_y := f32(150)

		for i in 0..<2 {
			item  := OptionsItem(i)
			fullscreen_res := item == .Resolution && settings.display_mode == .Fullscreen
			color := GREY if fullscreen_res else (YELLOW if item == options_focused^ else WHITE)
			y     := start_y + f32(i) * (item_h + spacing)
			draw_text(r, labels[i], {f32(WINDOW_WIDTH) * 0.18, y}, TEXT_SCALE, color)
			draw_text(r, fmt.tprintf("< %s >", values[i]), {f32(WINDOW_WIDTH) * 0.52, y}, TEXT_SCALE, color)
		}

		back_color := YELLOW if options_focused^ == .Back else WHITE
		back_y     := start_y + 2 * (item_h + spacing)
		back_w     := f32(ef.width("Back")) * TEXT_SCALE
		draw_text(r, "Back", {(f32(WINDOW_WIDTH) - back_w) / 2, back_y}, TEXT_SCALE, back_color)
	} else if screen^ == .GameOver {
		gameover_text := "GAME OVER"
		gameover_w    := f32(ef.width(gameover_text)) * TEXT_SCALE
		draw_text(r, gameover_text, {(f32(WINDOW_WIDTH) - gameover_w) / 2, f32(WINDOW_HEIGHT) / 2 - 60}, TEXT_SCALE, WHITE)

		score_str := fmt.tprintf("Score: %d", state.score)
		score_w   := f32(ef.width(score_str)) * TEXT_SCALE
		draw_text(r, score_str, {(f32(WINDOW_WIDTH) - score_w) / 2, f32(WINDOW_HEIGHT) / 2}, TEXT_SCALE, WHITE)

		hint_str := "Press Enter to return to menu"
		hint_w   := f32(ef.width(hint_str)) * TEXT_SCALE
		draw_text(r, hint_str, {(f32(WINDOW_WIDTH) - hint_w) / 2, f32(WINDOW_HEIGHT) / 2 + 60}, TEXT_SCALE, WHITE)
	} else {
		score_str := fmt.tprintf("Score: %d", state.score)
		score_w   := f32(ef.width(score_str)) * TEXT_SCALE
		score_pos := vec2{f32(WINDOW_WIDTH) - score_w - 10, 10}
		draw_text(r, score_str, score_pos, TEXT_SCALE, WHITE)

		draw_text(r, fmt.tprintf("Lives: %d", state.lives), {10, 10}, TEXT_SCALE, WHITE)

		draw_circle(r, state.ball.circle, WHITE)

		half := PADDLE_SIZE / 2
		draw_rect(r, Rect{min = state.paddle.pos - half, max = state.paddle.pos + half}, WHITE)

		for row in 0..<BLOCK_ROWS {
			for col in 0..<BLOCK_COLS {
				if state.blocks[row * BLOCK_COLS + col] {
					draw_rect(r, block_rect(col, row), WHITE)
				}
			}
		}

		if waiting_to_start^ {
			msg     := "Press any key to start"
			msg_w   := f32(ef.width(msg)) * TEXT_SCALE
			msg_pos := vec2{(f32(WINDOW_WIDTH) - msg_w) / 2, (f32(WINDOW_HEIGHT) - 8 * TEXT_SCALE) / 2}
			draw_text(r, msg, msg_pos, TEXT_SCALE, WHITE)
		} else if paused^ {
			draw_rect(r, Rect{min = {0, 0}, max = {WINDOW_WIDTH, WINDOW_HEIGHT}}, Color{0, 0, 0, 0.6})
			paused_text := "PAUSED"
			paused_w    := f32(ef.width(paused_text)) * TEXT_SCALE
			paused_pos  := vec2{(f32(WINDOW_WIDTH) - paused_w) / 2, (f32(WINDOW_HEIGHT) - 8 * TEXT_SCALE) / 2}
			draw_text(r, paused_text, paused_pos, TEXT_SCALE, WHITE)
		}
	}
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix)

	if infos, err := os.read_directory_by_path("screenshots", 0, context.allocator); err == nil {
		for fi in infos {
			os.remove(fi.fullpath)
		}
		os.file_info_slice_delete(infos, context.allocator)
	}
	os.make_directory("screenshots")

	if !SDL.Init(SDL.InitFlags{.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", SDL.GetError())
		return
	}
	defer SDL.Quit()

	SDL.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_PROFILE_MASK, 1)
	SDL.GL_SetAttribute(.DOUBLEBUFFER, 1)

	window := SDL.CreateWindow(WINDOW_TITLE, WINDOW_WIDTH, WINDOW_HEIGHT, SDL.WindowFlags{.OPENGL})
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

	left_held, right_held := false, false

	state := LevelState{
		ball   = {circle = {pos = {WINDOW_WIDTH / 2.0, WINDOW_HEIGHT / 2.0}, radius = BALL_RADIUS}, vel = BALL_SPEED},
		paddle = {pos = {f32(WINDOW_WIDTH) / 2.0, PADDLE_Y}},
		lives  = STARTING_LIVES,
	}
	for &b in state.blocks { b = true }

	screen             := GameScreen.MainMenu
	menu_selected      := 0
	waiting_to_start   := false
	paused             := false
	prev_counter      := SDL.GetPerformanceCounter()
	freq              := SDL.GetPerformanceFrequency()
	should_screenshot := false
	elapsed            : f32
	options_focused    := OptionsItem.DisplayMode

	running := true
	for running {
		free_all(context.temp_allocator)
		test_script_pump(&test_script, elapsed, &should_screenshot, &running)
		renderer_start_frame(&r)
		update(
			&prev_counter, freq,
			&running, &screen, &menu_selected, &waiting_to_start, &paused,
			&opts,
			&left_held, &right_held,
			&state,
			&elapsed,
			&should_screenshot,
			&r,
			window,
			&settings, &options_focused,
		)
		renderer_end_frame(&r, elapsed, &should_screenshot, window)
	}
}
