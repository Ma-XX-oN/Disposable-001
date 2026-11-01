def add_pair(left: int, right: int) -> int:
  assert isinstance(left, int) and not isinstance(left, bool)
  assert isinstance(right, int) and not isinstance(right, bool)
  return left + right
