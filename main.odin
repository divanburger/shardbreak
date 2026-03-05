package main

import "core:fmt"
import "core:flags"
import "core:os"
import glsl "core:math/linalg/glsl"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"
import stbi "vendor:stb/image"
import ef   "vendor:stb/easy_font"

WINDOW_TITLE  :: "Bouncing Ball"
WINDOW_WIDTH  :: 800
WINDOW_HEIGHT :: 600
WINDOW_SIZE   :: ivec2{WINDOW_WIDTH, WINDOW_HEIGHT}
BALL_RADIUS    :: 30.0
BALL_SPEED     :: vec2{250.0, 180.0}
SEGMENTS       :: 64
VERTEX_COUNT   :: SEGMENTS + 2

PADDLE_SIZE  :: vec2{120.0, 15.0}
PADDLE_SPEED :: 500.0
PADDLE_Y     :: f32(WINDOW_HEIGHT) - 60.0

BLOCK_COLS   :: 20
BLOCK_ROWS   :: 5
BLOCK_SIZE   :: vec2{36.0, 14.0}
BLOCK_GAP    :: vec2{3.0, 5.0}
BLOCK_AREA_Y :: 40.0

GAME_NAME      :: "gai"
TEXT_SCALE     :: f32(3)
STARTING_LIVES :: 3

VERT_SRC :: `#version 330 core
layout(location = 0) in vec2 a_offset;
uniform vec2 u_center;
uniform vec2 u_resolution;
void main() {
    vec2 screen_pos = u_center + a_offset;
    vec2 ndc = (screen_pos / u_resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
}`

FRAG_SRC :: `#version 330 core
uniform vec4 u_color;
out vec4 frag_color;
void main() {
    frag_color = u_color;
}`

generate_circle_offsets :: proc() -> [VERTEX_COUNT]vec2 {
	v: [VERTEX_COUNT]vec2
	v[0] = {0, 0}
	for i in 0..<SEGMENTS {
		angle := f32(i) / f32(SEGMENTS) * glsl.TAU
		v[i+1] = {glsl.cos(angle), glsl.sin(angle)} * BALL_RADIUS
	}
	v[SEGMENTS+1] = v[1]
	return v
}

quads_to_vbo :: proc(vbo: u32, text: string, pos: vec2, scale: f32, usage: u32) -> int {
	quads: [256]ef.Quad
	num_quads := ef.print(pos.x, pos.y, text, {255, 255, 255, 255}, quads[:], scale)
	verts: [256 * 6]vec2
	n := 0
	for i in 0..<num_quads {
		q := quads[i]
		verts[n+0] = {q.tl.v[0], q.tl.v[1]}
		verts[n+1] = {q.tr.v[0], q.tr.v[1]}
		verts[n+2] = {q.bl.v[0], q.bl.v[1]}
		verts[n+3] = {q.tr.v[0], q.tr.v[1]}
		verts[n+4] = {q.br.v[0], q.br.v[1]}
		verts[n+5] = {q.bl.v[0], q.bl.v[1]}
		n += 6
	}
	GL.BindBuffer(GL.ARRAY_BUFFER, vbo)
	GL.BufferData(GL.ARRAY_BUFFER, n * size_of(vec2), &verts, usage)
	return n
}

block_rect :: proc(col, row: int) -> Rect {
	area_x := (f32(WINDOW_WIDTH) - (BLOCK_COLS * (BLOCK_SIZE.x + BLOCK_GAP.x) - BLOCK_GAP.x)) / 2
	bmin := vec2{
		area_x + f32(col) * (BLOCK_SIZE.x + BLOCK_GAP.x),
		BLOCK_AREA_Y + f32(row) * (BLOCK_SIZE.y + BLOCK_GAP.y),
	}
	return {min = bmin, max = bmin + BLOCK_SIZE}
}

rebuild_block_vbo :: proc(vbo: u32, blocks: ^[BLOCK_COLS * BLOCK_ROWS]bool) -> int {
	verts: [BLOCK_COLS * BLOCK_ROWS * 6]vec2
	count := 0
	for row in 0..<BLOCK_ROWS {
		for col in 0..<BLOCK_COLS {
			if !blocks[row * BLOCK_COLS + col] { continue }
			r := block_rect(col, row)
			verts[count+0] = r.min
			verts[count+1] = {r.max.x, r.min.y}
			verts[count+2] = {r.min.x, r.max.y}
			verts[count+3] = {r.max.x, r.min.y}
			verts[count+4] = {r.min.x, r.max.y}
			verts[count+5] = r.max
			count += 6
		}
	}
	GL.BindBuffer(GL.ARRAY_BUFFER, vbo)
	if count > 0 {
		GL.BufferSubData(GL.ARRAY_BUFFER, 0, count * size_of(vec2), &verts)
	}
	return count
}

compile_shader_program :: proc(vert_src, frag_src: string) -> (program: u32, ok: bool) {
	compile :: proc(src: string, kind: u32) -> (id: u32, ok: bool) {
		id = GL.CreateShader(kind)
		src_ptr := cstring(raw_data(src))
		src_len := i32(len(src))
		GL.ShaderSource(id, 1, &src_ptr, &src_len)
		GL.CompileShader(id)
		status: i32
		GL.GetShaderiv(id, GL.COMPILE_STATUS, &status)
		if status == 0 {
			n: i32
			GL.GetShaderiv(id, GL.INFO_LOG_LENGTH, &n)
			buf := make([]u8, n)
			defer delete(buf)
			GL.GetShaderInfoLog(id, n, nil, raw_data(buf))
			fmt.eprintln("shader compile error:", string(buf))
			GL.DeleteShader(id)
			return 0, false
		}
		return id, true
	}

	vert := compile(vert_src, GL.VERTEX_SHADER) or_return
	defer GL.DeleteShader(vert)
	frag := compile(frag_src, GL.FRAGMENT_SHADER) or_return
	defer GL.DeleteShader(frag)

	program = GL.CreateProgram()
	GL.AttachShader(program, vert)
	GL.AttachShader(program, frag)
	GL.LinkProgram(program)

	status: i32
	GL.GetProgramiv(program, GL.LINK_STATUS, &status)
	if status == 0 {
		n: i32
		GL.GetProgramiv(program, GL.INFO_LOG_LENGTH, &n)
		buf := make([]u8, n)
		defer delete(buf)
		GL.GetProgramInfoLog(program, n, nil, raw_data(buf))
		fmt.eprintln("program link error:", string(buf))
		GL.DeleteProgram(program)
		return 0, false
	}
	return program, true
}

take_screenshot :: proc(counter: ^int) {
	pixels := make([]u8, WINDOW_SIZE.x * WINDOW_SIZE.y * 4)
	defer delete(pixels)

	GL.ReadPixels(0, 0, WINDOW_SIZE.x, WINDOW_SIZE.y, GL.RGBA, GL.UNSIGNED_BYTE, raw_data(pixels))

	counter^ += 1

	buf: [256]u8
	filename := fmt.bprintf(buf[:], "screenshots/screenshot_%04d.png\x00", counter^)

	if stbi.write_png(cstring(raw_data(buf[:])), WINDOW_SIZE.x, WINDOW_SIZE.y, 4, raw_data(pixels), WINDOW_SIZE.x * 4) == 0 {
		fmt.eprintln("screenshot failed")
	} else {
		fmt.println("screenshot saved:", filename[:len(filename)-1])
	}
}

main :: proc() {
	Options :: struct {
		screenshot_at:          f32  `usage:"Take a screenshot this many seconds after startup."`,
		quit_after_screenshot:  bool `usage:"Quit the game after the timed screenshot is taken."`,
	}
	opts := Options{screenshot_at = -1}
	flags.parse_or_exit(&opts, os.args, .Unix)

	if infos, err := os.read_directory_by_path("screenshots", 0, context.allocator); err == nil {
		for fi in infos {
			os.remove(fi.fullpath)
		}
		os.file_info_slice_delete(infos, context.allocator)
	}
	os.make_directory("screenshots")
	stbi.flip_vertically_on_write(true)

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

	program, ok := compile_shader_program(VERT_SRC, FRAG_SRC)
	if !ok {
		return
	}
	defer GL.DeleteProgram(program)

	vertices := generate_circle_offsets()
	vao, vbo: u32
	GL.GenVertexArrays(1, &vao)
	GL.GenBuffers(1, &vbo)
	defer GL.DeleteVertexArrays(1, &vao)
	defer GL.DeleteBuffers(1, &vbo)

	GL.BindVertexArray(vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, vbo)
	GL.BufferData(GL.ARRAY_BUFFER, size_of(vertices), &vertices, GL.STATIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	paddle_vao, paddle_vbo: u32
	GL.GenVertexArrays(1, &paddle_vao)
	GL.GenBuffers(1, &paddle_vbo)
	defer GL.DeleteVertexArrays(1, &paddle_vao)
	defer GL.DeleteBuffers(1, &paddle_vbo)

	GL.BindVertexArray(paddle_vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, paddle_vbo)
	GL.BufferData(GL.ARRAY_BUFFER, 4 * size_of(vec2), nil, GL.DYNAMIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	block_vao, block_vbo: u32
	GL.GenVertexArrays(1, &block_vao)
	GL.GenBuffers(1, &block_vbo)
	defer GL.DeleteVertexArrays(1, &block_vao)
	defer GL.DeleteBuffers(1, &block_vbo)

	GL.BindVertexArray(block_vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, block_vbo)
	GL.BufferData(GL.ARRAY_BUFFER, BLOCK_COLS * BLOCK_ROWS * 6 * size_of(vec2), nil, GL.DYNAMIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	text_vao, text_vbo: u32
	GL.GenVertexArrays(1, &text_vao)
	GL.GenBuffers(1, &text_vbo)
	defer GL.DeleteVertexArrays(1, &text_vao)
	defer GL.DeleteBuffers(1, &text_vbo)

	score_vao, score_vbo: u32
	GL.GenVertexArrays(1, &score_vao)
	GL.GenBuffers(1, &score_vbo)
	defer GL.DeleteVertexArrays(1, &score_vao)
	defer GL.DeleteBuffers(1, &score_vbo)

	GL.BindVertexArray(score_vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, score_vbo)
	GL.BufferData(GL.ARRAY_BUFFER, 256 * 6 * size_of(vec2), nil, GL.DYNAMIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	lives_vao, lives_vbo: u32
	GL.GenVertexArrays(1, &lives_vao)
	GL.GenBuffers(1, &lives_vbo)
	defer GL.DeleteVertexArrays(1, &lives_vao)
	defer GL.DeleteBuffers(1, &lives_vbo)

	GL.BindVertexArray(lives_vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, lives_vbo)
	GL.BufferData(GL.ARRAY_BUFFER, 256 * 6 * size_of(vec2), nil, GL.DYNAMIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	dim_vao, dim_vbo: u32
	GL.GenVertexArrays(1, &dim_vao)
	GL.GenBuffers(1, &dim_vbo)
	defer GL.DeleteVertexArrays(1, &dim_vao)
	defer GL.DeleteBuffers(1, &dim_vbo)
	{
		dim_verts := [4]vec2{{0, 0}, {WINDOW_WIDTH, 0}, {0, WINDOW_HEIGHT}, {WINDOW_WIDTH, WINDOW_HEIGHT}}
		GL.BindVertexArray(dim_vao)
		GL.BindBuffer(GL.ARRAY_BUFFER, dim_vbo)
		GL.BufferData(GL.ARRAY_BUFFER, size_of(dim_verts), &dim_verts, GL.STATIC_DRAW)
		GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
		GL.EnableVertexAttribArray(0)
		GL.BindVertexArray(0)
	}

	paused_vao, paused_vbo: u32
	GL.GenVertexArrays(1, &paused_vao)
	GL.GenBuffers(1, &paused_vbo)
	defer GL.DeleteVertexArrays(1, &paused_vao)
	defer GL.DeleteBuffers(1, &paused_vbo)

	paused_vert_count: int
	{
		paused_text := "PAUSED"
		paused_w    := f32(ef.width(paused_text)) * TEXT_SCALE
		paused_pos  := vec2{(f32(WINDOW_WIDTH) - paused_w) / 2, (f32(WINDOW_HEIGHT) - 8 * TEXT_SCALE) / 2}

		GL.BindVertexArray(paused_vao)
		GL.BindBuffer(GL.ARRAY_BUFFER, paused_vbo)
		GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
		GL.EnableVertexAttribArray(0)
		GL.BindVertexArray(0)

		paused_vert_count = quads_to_vbo(paused_vbo, paused_text, paused_pos, TEXT_SCALE, GL.STATIC_DRAW)
	}

	text_vert_count: int
	{
		text_w    := f32(ef.width(GAME_NAME)) * TEXT_SCALE
		title_pos := vec2{(f32(WINDOW_WIDTH) - text_w) / 2, 10}

		quads: [256]ef.Quad
		num_quads := ef.print(title_pos.x, title_pos.y, GAME_NAME, {255, 255, 255, 255}, quads[:], TEXT_SCALE)

		verts: [256 * 6]vec2
		for i in 0..<num_quads {
			q := quads[i]
			verts[text_vert_count+0] = {q.tl.v[0], q.tl.v[1]}
			verts[text_vert_count+1] = {q.tr.v[0], q.tr.v[1]}
			verts[text_vert_count+2] = {q.bl.v[0], q.bl.v[1]}
			verts[text_vert_count+3] = {q.tr.v[0], q.tr.v[1]}
			verts[text_vert_count+4] = {q.br.v[0], q.br.v[1]}
			verts[text_vert_count+5] = {q.bl.v[0], q.bl.v[1]}
			text_vert_count += 6
		}

		GL.BindVertexArray(text_vao)
		GL.BindBuffer(GL.ARRAY_BUFFER, text_vbo)
		GL.BufferData(GL.ARRAY_BUFFER, text_vert_count * size_of(vec2), &verts, GL.STATIC_DRAW)
		GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
		GL.EnableVertexAttribArray(0)
		GL.BindVertexArray(0)
	}

	GL.Enable(GL.BLEND)
	GL.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

	GL.UseProgram(program)
	loc_center     := GL.GetUniformLocation(program, "u_center")
	loc_resolution := GL.GetUniformLocation(program, "u_resolution")
	loc_color      := GL.GetUniformLocation(program, "u_color")
	GL.Uniform2f(loc_resolution, f32(WINDOW_SIZE.x), f32(WINDOW_SIZE.y))
	GL.Uniform4f(loc_color, 1, 1, 1, 1)

	ball_pos   := vec2{WINDOW_WIDTH / 2.0, WINDOW_HEIGHT / 2.0}
	ball_vel   := BALL_SPEED
	paddle_pos := vec2{f32(WINDOW_WIDTH) / 2.0, PADDLE_Y}
	left_held, right_held := false, false

	state := State{lives = STARTING_LIVES}
	for &b in state.blocks { b = true }
	block_vert_count := rebuild_block_vbo(block_vbo, &state.blocks)

	score_dirty      := true
	score_vert_count := 0

	lives_dirty      := true
	lives_vert_count := 0

	prev_counter := SDL.GetPerformanceCounter()
	freq         := SDL.GetPerformanceFrequency()

	paused := false

	screenshot_counter := 0
	should_screenshot  := false
	elapsed            : f32

	running := true
	for running {
		now := SDL.GetPerformanceCounter()
		dt  := f32(now - prev_counter) / f32(freq)
		prev_counter = now

		event: SDL.Event
		for SDL.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .KEY_DOWN:
			#partial switch event.key.scancode {
			case .ESCAPE:      running = false
			case .PAUSE, .P:   paused = !paused
			case .PRINTSCREEN: should_screenshot = true
			case .LEFT:        left_held  = true
			case .RIGHT:       right_held = true
			}
		case .KEY_UP:
			#partial switch event.key.scancode {
			case .LEFT:  left_held  = false
			case .RIGHT: right_held = false
			}
			}
		}

		elapsed += dt

		if opts.screenshot_at >= 0 && elapsed >= opts.screenshot_at {
			should_screenshot = true
			opts.screenshot_at = -1  // trigger only once
			if opts.quit_after_screenshot {
				running = false
			}
		}

		if !paused {

		if left_held  { paddle_pos.x -= PADDLE_SPEED * dt }
		if right_held { paddle_pos.x += PADDLE_SPEED * dt }
		paddle_pos.x = clamp(paddle_pos.x, PADDLE_SIZE.x / 2, f32(WINDOW_WIDTH) - PADDLE_SIZE.x / 2)

		ball_pos += ball_vel * dt

		// Block collision
		block_loop: for row in 0..<BLOCK_ROWS {
			for col in 0..<BLOCK_COLS {
				idx := row * BLOCK_COLS + col
				if !state.blocks[idx] { continue }
				r := block_rect(col, row)
				closest := clamp2(ball_pos, r.min, r.max)
				d := ball_pos - closest
				if glsl.dot(d, d) < BALL_RADIUS * BALL_RADIUS {
					state.blocks[idx] = false
					block_vert_count = rebuild_block_vbo(block_vbo, &state.blocks)
					state.score += 100
					score_dirty = true
					if ball_pos.x >= r.min.x && ball_pos.x <= r.max.x {
						ball_vel.y = -ball_vel.y
					} else {
						ball_vel.x = -ball_vel.x
					}
					break block_loop
				}
			}
		}

		// Paddle collision: ball bottom hits paddle top
		half_paddle := PADDLE_SIZE / 2
		paddle_top  := paddle_pos.y - half_paddle.y
		if ball_vel.y > 0 &&
		   ball_pos.y + BALL_RADIUS >= paddle_top &&
		   ball_pos.y - BALL_RADIUS <= paddle_pos.y + half_paddle.y &&
		   ball_pos.x + BALL_RADIUS >= paddle_pos.x - half_paddle.x &&
		   ball_pos.x - BALL_RADIUS <= paddle_pos.x + half_paddle.x {
			ball_pos.y = paddle_top - BALL_RADIUS
			ball_vel.y = -abs(ball_vel.y)
		}

		if ball_pos.x - BALL_RADIUS < 0            { ball_pos.x = BALL_RADIUS;                ball_vel.x =  abs(ball_vel.x) }
		if ball_pos.x + BALL_RADIUS > WINDOW_WIDTH { ball_pos.x = WINDOW_WIDTH - BALL_RADIUS; ball_vel.x = -abs(ball_vel.x) }
		if ball_pos.y - BALL_RADIUS < 0            { ball_pos.y = BALL_RADIUS;                ball_vel.y =  abs(ball_vel.y) }
		if ball_pos.y - BALL_RADIUS > WINDOW_HEIGHT {
			state.lives -= 1
			lives_dirty = true
			if state.lives <= 0 {
				running = false
			} else {
				ball_pos = {paddle_pos.x, paddle_pos.y - PADDLE_SIZE.y/2 - BALL_RADIUS - 5}
				ball_vel = {BALL_SPEED.x, -abs(BALL_SPEED.y)}
			}
		}

		} // end !paused

		GL.ClearColor(0, 0, 0, 1)
		GL.Clear(GL.COLOR_BUFFER_BIT)
		GL.UseProgram(program)
		GL.Uniform2f(loc_center, ball_pos.x, ball_pos.y)
		GL.BindVertexArray(vao)
		GL.DrawArrays(GL.TRIANGLE_FAN, 0, VERTEX_COUNT)

		// Draw paddle: upload corners as actual screen positions, center uniform zeroed
		half := PADDLE_SIZE / 2
		paddle_verts := [4]vec2{
			paddle_pos + {-half.x, -half.y},
			paddle_pos + { half.x, -half.y},
			paddle_pos + {-half.x,  half.y},
			paddle_pos + { half.x,  half.y},
		}
		GL.BindBuffer(GL.ARRAY_BUFFER, paddle_vbo)
		GL.BufferSubData(GL.ARRAY_BUFFER, 0, size_of(paddle_verts), &paddle_verts)
		GL.Uniform2f(loc_center, 0, 0)
		GL.BindVertexArray(paddle_vao)
		GL.DrawArrays(GL.TRIANGLE_STRIP, 0, 4)

		// Draw blocks
		if block_vert_count > 0 {
			GL.BindVertexArray(block_vao)
			GL.DrawArrays(GL.TRIANGLES, 0, i32(block_vert_count))
		}

		// Draw game name
		GL.BindVertexArray(text_vao)
		GL.DrawArrays(GL.TRIANGLES, 0, i32(text_vert_count))

		// Rebuild and draw score
		if score_dirty {
			score_buf: [32]u8
			score_str := fmt.bprintf(score_buf[:], "Score: %d", state.score)
			score_w   := f32(ef.width(score_str)) * TEXT_SCALE
			score_pos := vec2{f32(WINDOW_WIDTH) - score_w - 10, 10}
			score_vert_count = quads_to_vbo(score_vbo, score_str, score_pos, TEXT_SCALE, GL.DYNAMIC_DRAW)
			score_dirty = false
		}
		GL.BindVertexArray(score_vao)
		GL.DrawArrays(GL.TRIANGLES, 0, i32(score_vert_count))

		// Rebuild and draw lives
		if lives_dirty {
			lives_buf: [32]u8
			lives_str := fmt.bprintf(lives_buf[:], "Lives: %d", state.lives)
			lives_vert_count = quads_to_vbo(lives_vbo, lives_str, {10, 10}, TEXT_SCALE, GL.DYNAMIC_DRAW)
			lives_dirty = false
		}
		GL.BindVertexArray(lives_vao)
		GL.DrawArrays(GL.TRIANGLES, 0, i32(lives_vert_count))

		// Draw dim overlay and paused text
		if paused {
			GL.Uniform2f(loc_center, 0, 0)
			GL.Uniform4f(loc_color, 0, 0, 0, 0.6)
			GL.BindVertexArray(dim_vao)
			GL.DrawArrays(GL.TRIANGLE_STRIP, 0, 4)
			GL.Uniform4f(loc_color, 1, 1, 1, 1)
			GL.BindVertexArray(paused_vao)
			GL.DrawArrays(GL.TRIANGLES, 0, i32(paused_vert_count))
		}

		if should_screenshot {
			take_screenshot(&screenshot_counter)
			should_screenshot = false
		}

		SDL.GL_SwapWindow(window)
	}
}
