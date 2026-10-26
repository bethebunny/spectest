spec sorting

# Sorting as a value-to-value function, a stable sort by key, and an in-place sort.

fn sort<T: Ord>(xs: list<T>) -> list<T>
  partition xs
    empty      = len(xs) == 0
    single     = len(xs) == 1
    unique     = len(xs) > 1 and distinct(xs)
    duplicates = len(xs) > 1 and not distinct(xs)
  ensures permutation: is_permutation(result, xs)
  ensures ordered: is_sorted(result)

# Sorts pairs by their first element only, keeping the input order of equal keys.
fn sort_by_first<K: Ord, V: Eq>(xs: list<(K, V)>) -> list<(K, V)>
  ensures permutation: is_permutation(result, xs)
  ensures ordered: is_sorted(map(p in result: p.0))
  ensures stable: all(p in xs: filter(q in result: q.0 == p.0) == filter(q in xs: q.0 == p.0))

model MutableList<T>
  observe items: list<T>

fn sort_in_place<T: Ord>(xs: MutableList<T>)
  modifies xs
  ensures permutation: is_permutation(xs.items, old(xs.items))
  ensures ordered: is_sorted(xs.items)
