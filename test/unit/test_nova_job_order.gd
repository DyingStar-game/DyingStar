extends GutTest
## PlanetTerrain.nova_job_order: the waiting Nova layings by urgency, the most urgent last, so that taking them
## off the end gives, one after the other, what scanning them all for the least urgency gave each time.


func test_popping_the_order_is_scanning_for_the_least_urgent_each_time() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var waiting := {}
	for id in 300:
		waiting[id + 1] = [rng.randf_range(-500.0, 2000.0) if id % 9 != 0 else 100.0]  # some ties
	var urgency := func(entry: Array) -> float: return float(entry[0])
	var order := PlanetTerrain.nova_job_order(waiting, urgency)
	assert_eq(order.size(), waiting.size())
	var left := waiting.duplicate()
	while not order.is_empty():
		var popped: int = order.pop_back()
		var best := -1
		var best_u := INF
		for id: int in left.keys():  # the old scan: the first of the least urgency, in the order they came
			var u := float(urgency.call(left[id]))
			if u < best_u:
				best_u = u
				best = id
		assert_eq(popped, best)
		left.erase(best)


func test_nothing_waiting_orders_nothing() -> void:
	assert_eq(PlanetTerrain.nova_job_order({}, func(_e: Array) -> float: return 0.0), [] as Array[int])


func test_keeping_a_few_keeps_the_most_urgent_in_the_same_order() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var waiting := {}
	for id in 500:
		waiting[id + 1] = [float(rng.randi_range(0, 60))]  # many ties
	var urgency := func(entry: Array) -> float: return float(entry[0])
	var all := PlanetTerrain.nova_job_order(waiting, urgency)
	var few := PlanetTerrain.nova_job_order(waiting, urgency, 32)
	assert_eq(few.size(), 32)
	assert_eq(few, all.slice(all.size() - 32), "the last 32 of the whole order, in order")


func test_ties_go_to_the_oldest_whatever_order_they_come_in() -> void:
	var waiting := {}
	for id: int in [9, 3, 7, 1, 5]:
		waiting[id] = [1.0]
	var urgency := func(entry: Array) -> float: return float(entry[0])
	assert_eq(PlanetTerrain.nova_job_order(waiting, urgency), [9, 7, 5, 3, 1] as Array[int], "the oldest last")
	assert_eq(PlanetTerrain.nova_job_order(waiting, urgency, 2), [3, 1] as Array[int])
