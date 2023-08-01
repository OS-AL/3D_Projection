local utils = require("Utilities")

-- Local references to globals for optimization
local math_pi <const> = math.pi
local math_floor <const> = math.floor
local math_abs <const> = math.abs
local math_sin <const> = math.sin
local math_cos <const> = math.cos

local sd_draw_triangle <const> = scriptdraw.draw_triangle
local sd_draw_rect_ext <const> = scriptdraw.draw_rect_ext

-- Locals
local aspect_ratio <const> = graphics.get_screen_width()/graphics.get_screen_height()

local function parse_obj(path)
	local model = {path = path}

	local file = io.open(path, "r")
	if not file then return end
	local contents = file:read("a")
	file:close()

	local vert_index = 1
	model.vertices = {}
	model.vertex_colors = {}
	for x, y, z, r, g, b in contents:gmatch("v%s(%-?[0-9%.]+)%s(%-?[0-9%.]+)%s(%-?[0-9%.]+)%s?(%-?[0-9%.]*)%s?(%-?[0-9%.]*)%s?(%-?[0-9%.]*)") do
		model.vertices[vert_index] = {{tonumber(x), tonumber(y), tonumber(z)}}
		if tonumber(r) and tonumber(g) and tonumber(b) then
			model.vertex_colors[vert_index] = 255 << 24 | math_floor(tonumber(b) * 255) << 16 | math_floor(tonumber(g) * 255) << 8 | math_floor(tonumber(r) * 255)
		end
		vert_index = vert_index + 1
	end

	local face_index = 1
	model.faces = {}
	for line in contents:gmatch("f ([%d%s]+)") do
		local connections = {}
		local connect_index = 1
		for connection in line:gmatch("([0-9%.]+)") do
			connections[connect_index] = tonumber(connection)
			connect_index = connect_index + 1
		end
		model.faces[face_index] = connections
		face_index = face_index + 1
	end

	return model
end

local function matmult(a, b)
	local result = {}
	local b_columns = #b[1]
	local b_rows = #b
	for i = 1, #a do
		local result_row = {}
		for j = 1, b_columns do
			local sum = 0
			for k = 1, b_rows do
				sum = sum + a[i][k] * b[k][j]
			end
			result_row[j] = sum
		end
		result[i] = result_row
	end
	return result
end

-- these 2 vert_matmult functions are less efficient than the 3rd one

--[[ local function vert_matmult(vert, mat)
	local result = {}
	vert = vert[1]
	for i = 1, 3 do
		local sum = vert[1] * mat[1][i]
		for j = 2, 3 do
			sum = sum + vert[j] * mat[j][i]
		end
		result[i] = sum
	end
	return result
end ]]

--[[ local function vert_matmult(vert, mat)
	local result = {}
	vert = vert[1]
	for i = 1, 3 do
		local sum = vert[1] * mat[1][i]
		sum = sum + vert[2] * mat[2][i]
		sum = sum + vert[3] * mat[3][i]
		result[i] = sum
	end
	return result
end ]]

local vert_matmult
do
	local new_vert = {}
	function vert_matmult(vert, mat)
		vert = vert[1]

		local vx <const> = vert[1]
		local vy <const> = vert[2]
		local vz <const> = vert[3]
		local mata <const> = mat[1]
		local matb <const> = mat[2]
		local matc <const> = mat[3]

		local x = vx * mata[1]
		x = x + vy * matb[1]
		x = x + vz * matc[1]

		local y = vx * mata[2]
		y = y + vy * matb[2]
		y = y + vz * matc[2]

		local z = vx * mata[3]
		z = z + vy * matb[3]
		z = z + vz * matc[3]

		new_vert[1] = x
		new_vert[2] = y
		new_vert[3] = z

		return new_vert
	end
end

local get_rot
do
	local update_table = {
		x = {2, 3},
		y = {1, 3},
		z = {1, 2}
	}
	local stuff = { -- the rotation matrix was taken from wikipedia
		x = {
			{1, 0, 0},
			{0, math_cos(0), -math_sin(0)},
			{0, math_sin(0), math_cos(0)}
		},
		y = {
			{math_cos(0), 0, math_sin(0)},
			{0, 1, 0},
			{-math_sin(0), 0, math_cos(0)}
		},
		z = {
			{math_cos(0), -math_sin(0), 0},
			{math_sin(0), math_cos(0), 0},
			{0, 0, 1}
		}
	}
	function get_rot(axis, angle)
		local rot = stuff[axis]
		local update = update_table[axis]
		local sin = math_sin(angle)
		local cos = math_cos(angle)
		for i = update[1], update[2], axis == "y" and 2 or 1 do
			local is_first = i == update[1]
			rot[i][update[1]] = is_first and cos or (axis == "y" and -sin or sin)
			rot[i][update[2]] = is_first and (axis == "y" and sin or -sin) or cos
		end
		return rot
	end
end

local get_v2
do
	local v2r = utils.new_reusable_v2(26509)
	local new_vert = {{}}
	local new_vert_2 = new_vert[1]
	local far = 50
	local near = 0.1
	function get_v2(vert, rot, scale, offset, distance, cam)
		if cam then
			vert = vert[1]
			new_vert_2[1] = vert[1] * scale - cam.x
			new_vert_2[2] = vert[2] * scale - cam.y
			new_vert_2[3] = vert[3] * scale - cam.z
			vert = new_vert
		end
		local rotated = rot and vert_matmult(vert, rot) or vert

		local z = distance and 1 / (distance - rotated[3]) or 1 -- this was taken from a youtube tutorial: https://www.youtube.com/watch?v=p4Iz0XJY-Qk

		return v2r(rotated[1] / aspect_ratio * z + (offset and offset.x or 0), rotated[2] * z + (offset and offset.y or 0)), rotated[3] * ((far+near)/(far-near))
	end
end

local function get_vertex_color(vcol, depth)
	local depthmul = ((depth + 2) / 4)
	depthmul = depthmul < 0 and 0 or depthmul
	depthmul = depthmul > 1 and 1 or depthmul

	local r = math_floor(depthmul * (vcol & 0xFF))
	local g = math_floor(depthmul * (vcol >> 8 & 0xFF))
	local b = math_floor(depthmul * (vcol >> 16 & 0xFF))

	return 0xFF000000 | b << 16 | g << 8 | r
end

local function check_face(face, vertices, depth, near, far)
	local out_of_scope = 0
	for i = 1, #face do
		local vert = vertices[face[i]]
		if not depth[face[i]] or (near and depth[face[i]] > near) or (far and depth[face[i]] < far) then
			return false
		end
		if math_abs(vert.x) > 1 or math_abs(vert.y) > 1 then
			out_of_scope = out_of_scope + 1
		end
	end
	return out_of_scope < 4
end

local draw_model
do
	local vertices <const> = {}
	local depth <const> = {}
	local culled_faces <const> = {}

	local function depth_sort(a, b) -- the commented code below provides slightly better depth sort but at the cost of performance
		-- local asum = depth[a[1]] + depth[a[2]]
		-- asum = asum + (a[3] and depth[a[3]] + (a[4] and depth[a[4]] or 0) or 0)
		-- local bsum = depth[b[1]] + depth[b[2]]
		-- bsum = bsum + (b[3] and depth[b[3]] + (b[4] and depth[b[4]] or 0) or 0)
		return depth[a[1]] < depth[b[1]]
	end

	function draw_model(model, cam, pos, rot, color, shading_strength, scale, distance, near, far, rot_y_priority, fix_depth, wireframe, wireframe_only)
		wireframe_only = wireframe_only and wireframe

		for i = 1, #vertices do
			vertices[i] = nil
			depth[i] = nil
		end
		for i = 1, #culled_faces do
			culled_faces[i] = nil
		end

		local is_v3 = type(rot) == "userdata"
		local rotX <const> = get_rot("x", is_v3 and rot.x or rot)
		local rotY <const> = get_rot("y", is_v3 and rot.y or rot)
		local rotZ <const> = get_rot("z", is_v3 and rot.z or rot)

		local combined_rot = matmult(rot_y_priority and rotY or rotX, rot_y_priority and rotX or rotY)
		combined_rot = matmult(combined_rot, rotZ)

		local model_verts <const> = model.vertices
		for i = 1, #model_verts do
			vertices[i], depth[i] = get_v2(model_verts[i], combined_rot, scale, pos, distance, cam)
		end

		local culled_index = 1
		local faces <const> = model.faces
		for i = 1, #faces do
			local face = faces[i]
			if check_face(face, vertices, depth, near, far) then
				culled_faces[culled_index] = face
				culled_index = culled_index + 1
			end
		end
		if not wireframe_only and fix_depth then
			table.sort(culled_faces, depth_sort)
		end

		local vertex_colors <const> = model.vertex_colors
		if wireframe then
			for i = 1, #culled_faces do
				local face = culled_faces[i]
				for j = 1, #face do
					scriptdraw.draw_line(vertices[face[j]], vertices[face[j+1]] or vertices[face[1]], 0xFF, vertex_colors[face[j]] or color)
				end
			end
		end
		if not wireframe_only then
			local is_shaded = shading_strength > 0
			for i = 1, #culled_faces do
				local face = culled_faces[i]

				local face_1 = face[1]
				local face_2 = face[2]
				local face_3 = face[3]

				local color_1 = is_shaded and get_vertex_color(vertex_colors[face_1] or color, depth[face_1] * shading_strength) or vertex_colors[face_1]
				local color_2 = is_shaded and get_vertex_color(vertex_colors[face_2] or color, depth[face_2] * shading_strength) or vertex_colors[face_2]
				local color_3 = is_shaded and get_vertex_color(vertex_colors[face_3] or color, depth[face_3] * shading_strength) or vertex_colors[face_3]

				if #face > 3 then
					local face_4 = face[4]
					local color_4 = is_shaded and get_vertex_color(vertex_colors[face_4] or color, depth[face_4] * shading_strength) or vertex_colors[face_4]
					sd_draw_rect_ext(vertices[face_1], vertices[face_2], vertices[face_3], vertices[face_4], color_1 or color, color_2 or color, color_3 or color, color_4 or color)
				else
					sd_draw_triangle(vertices[face_1], vertices[face_2], vertices[face_3], color_1 or color, color_2 or color, color_3 or color)
				end
			end
		end
	end
end

menu.create_thread(function()
	local model = parse_obj("model.obj") -- model to load
	local rot = v3(0, 0, 0)
	local radToDegrees = 180/math_pi
	local key = {
		w = Key(),
		a = Key(),
		s = Key(),
		d = Key()
	}
	key.w:push_vk(0x57)
	key.a:push_vk(0x41)
	key.s:push_vk(0x53)
	key.d:push_vk(0x44)

	local campos = v3(0, 1, 0)
	local speed_modifier

	local center = v2()
	local fullscreen = v2(2, 2)

	while true do
		local camrot = cam.get_gameplay_cam_rot()
		rot.y = camrot.z/radToDegrees
		rot.x = camrot.x/radToDegrees

		scriptdraw.draw_rect(center, fullscreen, 0xFF000000)

		--model, camera position, screen transform, rotation, color (if vertex color isnt found), shading_strength, scale, distance, rot_y_priority, fix_depth (draws far faces first), wireframe, wireframe_only
		draw_model(model, campos, nil, rot, 0xFFFF00AA, 0.02, 1, 0.1, -0.01, -100, true, true, true, true)

		speed_modifier = 8 / (gameplay.get_frame_time() * 100)
		if key.w:is_down() then
			camrot:transformRotToDir()
			campos.z = campos.z - camrot.y / speed_modifier
			campos.x = campos.x + camrot.x / speed_modifier
		end
		if key.a:is_down() then
			camrot = cam.get_gameplay_cam_rot()
			camrot.z = camrot.z + 90
			camrot:transformRotToDir()
			campos.z = campos.z - camrot.y / speed_modifier
			campos.x = campos.x + camrot.x / speed_modifier
		end
		if key.s:is_down() then
			camrot = cam.get_gameplay_cam_rot()
			camrot.z = camrot.z + 180
			camrot:transformRotToDir()
			campos.z = campos.z - camrot.y / speed_modifier
			campos.x = campos.x + camrot.x / speed_modifier
		end
		if key.d:is_down() then
			camrot = cam.get_gameplay_cam_rot()
			camrot.z = camrot.z - 90
			camrot:transformRotToDir()
			campos.z = campos.z - camrot.y / speed_modifier
			campos.x = campos.x + camrot.x / speed_modifier
		end

		system.wait(0)
	end
end)