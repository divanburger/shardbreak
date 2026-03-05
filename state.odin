package main

State :: struct {
	lives:  int,
	score:  int,
	blocks: [BLOCK_COLS * BLOCK_ROWS]bool,
}
