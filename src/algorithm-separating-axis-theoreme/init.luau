--!strict
--!native
--!optimize 2

type SAT = {
	read compute_axises_pack: (self: SAT, left: { vector }, right: { vector }) -> { vector },
	read compute_cross_products: (self: SAT, left: { vector }, right: { vector }) -> { vector },
	read compute_generator: (
		self: SAT,
		left: { vector },
		right: { vector },
		half_left: vector,
		half_right: vector,
		center_left: vector,
		center_right: vector
	) -> generator,
	read compute_projection: (self: SAT, generator: generator) -> projection,
	read compute_mtv: (self: SAT, project: projection) -> mtv,
}

type projection = {
	read distance: { read number },
	read left_radius: { read number },
	read right_radius: { read number },
	read pack: { read vector },
	read center: vector,
}

type generator = {
	read left: { vector },
	read right: { vector },
	read half_left: vector,
	read half_right: vector,
	read center_left: vector,
	read center_right: vector,
}

type mtv = {
	read axis: vector,
	read mtv: number,
}

const SAT: SAT = table.freeze({
	compute_axises_pack = function(self: SAT, left: { vector }, right: { vector }): { vector }
		const result: { vector } = {}

		for _, axis_left in left do
			table.insert(result, vector.normalize(axis_left))
		end

		for _, axis_right in right do
			table.insert(result, vector.normalize(axis_right))
		end

		return result
	end,

	compute_cross_products = function(self: SAT, left: { vector }, right: { vector }): { vector }
		const result: { vector } = {}

		for _, left_axis in left do
			for _, right_axis in right do
				const new: vector = vector.cross(left_axis, right_axis)

				if vector.dot(new, new) > 1e-8 then
					table.insert(result, vector.normalize(new))
				end
			end
		end

		return result
	end,

	compute_generator = function(
		self: SAT,
		left: { vector },
		right: { vector },
		half_left: vector,
		half_right: vector,
		center_left: vector,
		center_right: vector
	): generator
		const generator = table.freeze({
			left = left,
			right = right,
			half_left = half_left,
			half_right = half_right,
			center_left = center_left,
			center_right = center_right,
		})

		return generator
	end,

	compute_projection = function(self: SAT, generator: generator): projection
		const axises_pack = self:compute_axises_pack(generator.left, generator.right)
		const cross_products = self:compute_cross_products(generator.left, generator.right)
		const pack = table.create(#axises_pack + #cross_products, vector.zero)

		table.move(axises_pack, 1, #axises_pack, 1, pack)
		table.move(cross_products, 1, #cross_products, #axises_pack + 1, pack)

		const center = generator.center_left - generator.center_right
		const half_left = generator.half_left
		const half_right = generator.half_right
		const left = generator.left
		const right = generator.right

		const projection = table.freeze({
			distance = {},
			left_radius = {},
			right_radius = {},
			pack = pack,
			center = center,
		})

		for _, axis in pack do
			table.insert(projection.distance, math.abs(vector.dot(center, axis)))

			table.insert(
				projection.left_radius,
				(half_left.x * math.abs(vector.dot(axis, left[1])))
					+ (half_left.y * math.abs(vector.dot(axis, left[2])))
					+ (half_left.z * math.abs(vector.dot(axis, left[3])))
			)

			table.insert(
				projection.right_radius,
				(half_right.x * math.abs(vector.dot(axis, right[1])))
					+ (half_right.y * math.abs(vector.dot(axis, right[2])))
					+ (half_right.z * math.abs(vector.dot(axis, right[3])))
			)
		end

		table.freeze(projection.distance)
		table.freeze(projection.left_radius)
		table.freeze(projection.right_radius)
		table.freeze(projection.pack)

		return projection
	end,

	compute_mtv = function(self: SAT, project: projection): mtv
		local min: number = math.huge
		local axis: vector = vector.zero

		for i, cross in project.pack do
			const overlap: number = project.left_radius[i] + project.right_radius[i] - project.distance[i]

			if overlap < 0 then
				return table.freeze({
					mtv = -math.huge,
					axis = -vector.zero,
				})
			end

			if overlap < min then
				min = overlap
				axis = cross

				if vector.dot(axis, project.center) < 0 then
					axis = -axis
				end
			end
		end

		return table.freeze({
			mtv = min,
			axis = axis,
		})
	end,
})

return SAT
