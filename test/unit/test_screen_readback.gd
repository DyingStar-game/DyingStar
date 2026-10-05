extends GutTest
## ScreenReadback draws the window's frame at exactly the capture's size. A TextureRect left to its
## default never shrinks below its texture, and after a window resize the window texture reported a
## larger (canvas_items-scaled) size than the window: the frame came out enlarged, its right and bottom
## edges cut off the screenshot.


func test_the_frame_is_drawn_at_the_capture_size_even_below_its_texture_size() -> void:
	var readback := ScreenReadback.new()
	add_child_autofree(readback)
	var rect : TextureRect = readback.get_child(0)
	rect.texture = ImageTexture.create_from_image(Image.create(3490, 1389, false, Image.FORMAT_RGBA8))
	rect.size = Vector2(3440, 1369)
	assert_eq(rect.size, Vector2(3440, 1369), "the texture's own size must not hold the rect bigger")
