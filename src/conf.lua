function love.conf(t)
	t.identity = "luareader"
	t.version = "11.5"

	t.window.title = "luareader"
	t.window.width = 860
	t.window.height = 1000
	t.window.minwidth = 360
	t.window.minheight = 300
	t.window.resizable = true
	t.window.highdpi = true
	t.window.vsync = 1
	t.window.msaa = 4 -- smooth edges on circles, rounded corners and icons

	t.modules.audio = false
	t.modules.sound = false
	t.modules.joystick = false
	t.modules.physics = false
	t.modules.video = false
end
