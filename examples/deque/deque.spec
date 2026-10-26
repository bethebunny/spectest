spec deque

# A double-ended queue with an optional bound, like Python's collections.deque.
# Appending to a full bounded deque drops an item from the opposite end.
# The bound is fixed when the deque is made: no method changes maxlen.

error IndexError

interface Deque<T: Eq>
  observe items: list<T>
  observe maxlen: option<u64>
  invariant within_bound: is_none(maxlen) or len(items) <= unwrap(maxlen)

  new empty() -> Deque
    ensures items: len(result.items) == 0
    ensures unbounded: is_none(result.maxlen)

  new bounded(n: u8) -> Deque
    ensures items: len(result.items) == 0
    ensures maxlen: result.maxlen == some(n)

  method append(self, x: T)
    modifies self
    ensures items: let ys = old(self.items) + [x] in
      self.items == (if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen)
                     then ys[len(ys) - unwrap(self.maxlen):len(ys)] else ys)
    ensures maxlen: self.maxlen == old(self.maxlen)

  method appendleft(self, x: T)
    modifies self
    ensures items: let ys = [x] + old(self.items) in
      self.items == (if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen)
                     then ys[0:unwrap(self.maxlen)] else ys)
    ensures maxlen: self.maxlen == old(self.maxlen)

  method pop(self) -> T
    raises IndexError when len(self.items) == 0
    modifies self
    ensures value: result == old(self.items)[len(old(self.items)) - 1]
    ensures items: self.items == old(self.items)[0:len(old(self.items)) - 1]
    ensures maxlen: self.maxlen == old(self.maxlen)

  method popleft(self) -> T
    raises IndexError when len(self.items) == 0
    modifies self
    ensures value: result == old(self.items)[0]
    ensures items: self.items == old(self.items)[1:len(old(self.items))]
    ensures maxlen: self.maxlen == old(self.maxlen)

  method rotate(self, n: i8)
    modifies self
    ensures items: let xs = old(self.items) in
      self.items == (if len(xs) == 0 then xs
                     else xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)])
    ensures maxlen: self.maxlen == old(self.maxlen)
