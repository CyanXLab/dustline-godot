class_name SourceRandom extends RefCounted
## Park-Miller (MINSTD) + Bays-Durham shuffle — 与原作 SourceRandom 逐位一致
const IA := 16807
const IM := 2147483647
const IQ := 127773
const IR := 2836
const NDIV := 67108864.0

var _shuffle: PackedInt32Array = PackedInt32Array()
var _seed: int
var _last := 0

func _init(value: int) -> void:
	_shuffle.resize(32)
	_seed = value if value < 0 else -value

func _next() -> int:
	var k: int
	if _seed <= 0 or _last == 0:
		_seed = maxi(-_seed, 1)
		for i in range(39, -1, -1):
			k = int(_seed / float(IQ))
			_seed = IA * (_seed - k * IQ) - IR * k
			if _seed < 0: _seed += IM
			if i < 32: _shuffle[i] = _seed
		_last = _shuffle[0]
	k = int(_seed / float(IQ))
	_seed = IA * (_seed - k * IQ) - IR * k
	if _seed < 0: _seed += IM
	var idx := int(_last / NDIV)
	_last = _shuffle[idx]
	_shuffle[idx] = _seed
	return _last

func int_range(minv: int, maxv: int) -> int:
	var n := maxv - minv + 1
	if n <= 1: return minv
	var lim := IM - (2147483648 % n)
	var v := 0
	while true:
		v = _next()
		if v <= lim: break
	return minv + (v % n)

func unit() -> float:
	return minf(0.9999999, _next() * 4.656612875245797e-10)

func rng_range(minv: float, maxv: float) -> float:
	return minv + (maxv - minv) * unit()
