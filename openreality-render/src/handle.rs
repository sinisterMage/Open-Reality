use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

/// Type-safe handle store mapping opaque u64 handles to values.
/// Julia holds these handles and passes them back via FFI.
pub struct HandleStore<T> {
    items: HashMap<u64, T>,
}

impl<T> HandleStore<T> {
    pub fn new() -> Self {
        Self {
            items: HashMap::new(),
        }
    }

    /// Insert an item and return its opaque handle.
    pub fn insert(&mut self, item: T) -> u64 {
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        self.items.insert(handle, item);
        handle
    }

    /// Get an immutable reference by handle.
    pub fn get(&self, handle: u64) -> Option<&T> {
        self.items.get(&handle)
    }

    /// Get a mutable reference by handle.
    pub fn get_mut(&mut self, handle: u64) -> Option<&mut T> {
        self.items.get_mut(&handle)
    }

    /// Remove and return the item.
    pub fn remove(&mut self, handle: u64) -> Option<T> {
        self.items.remove(&handle)
    }

    /// Iterate over all items.
    pub fn iter(&self) -> impl Iterator<Item = (&u64, &T)> {
        self.items.iter()
    }

    /// Number of stored items.
    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// Clear all items, running destructors.
    pub fn clear(&mut self) {
        self.items.clear();
    }
}

impl<T> Default for HandleStore<T> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_get() {
        let mut store = HandleStore::new();
        let handle = store.insert(42i32);
        assert_eq!(store.get(handle), Some(&42));
    }

    #[test]
    fn test_insert_returns_unique_handles() {
        let mut store = HandleStore::new();
        let h1 = store.insert("a");
        let h2 = store.insert("b");
        let h3 = store.insert("c");
        assert_ne!(h1, h2);
        assert_ne!(h2, h3);
        assert_ne!(h1, h3);
    }

    #[test]
    fn test_get_nonexistent_returns_none() {
        let store = HandleStore::<String>::new();
        assert_eq!(store.get(999999), None);
    }

    #[test]
    fn test_remove() {
        let mut store = HandleStore::new();
        let handle = store.insert("hello");
        assert_eq!(store.len(), 1);
        let removed = store.remove(handle);
        assert_eq!(removed, Some("hello"));
        assert_eq!(store.get(handle), None);
        assert_eq!(store.len(), 0);
    }

    #[test]
    fn test_remove_nonexistent() {
        let mut store = HandleStore::<i32>::new();
        assert_eq!(store.remove(999999), None);
    }

    #[test]
    fn test_get_mut() {
        let mut store = HandleStore::new();
        let handle = store.insert(vec![1, 2, 3]);
        store.get_mut(handle).unwrap().push(4);
        assert_eq!(store.get(handle), Some(&vec![1, 2, 3, 4]));
    }

    #[test]
    fn test_clear() {
        let mut store = HandleStore::new();
        let h1 = store.insert(1);
        let h2 = store.insert(2);
        store.clear();
        assert_eq!(store.len(), 0);
        assert_eq!(store.get(h1), None);
        assert_eq!(store.get(h2), None);
    }

    #[test]
    fn test_len() {
        let mut store = HandleStore::new();
        assert_eq!(store.len(), 0);
        let h = store.insert("x");
        assert_eq!(store.len(), 1);
        store.insert("y");
        assert_eq!(store.len(), 2);
        store.remove(h);
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn test_iter() {
        let mut store = HandleStore::new();
        let h1 = store.insert(10);
        let h2 = store.insert(20);
        let h3 = store.insert(30);
        let mut items: Vec<_> = store.iter().map(|(&h, &v)| (h, v)).collect();
        items.sort_by_key(|&(h, _)| h);
        assert_eq!(items.len(), 3);
        assert!(items.contains(&(h1, 10)));
        assert!(items.contains(&(h2, 20)));
        assert!(items.contains(&(h3, 30)));
    }

    #[test]
    fn test_default() {
        let store = HandleStore::<String>::default();
        assert_eq!(store.len(), 0);
    }
}
