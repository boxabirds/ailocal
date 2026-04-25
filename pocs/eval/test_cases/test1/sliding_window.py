def max_in_window(nums, k):
    """Return list of max values in each sliding window of size k."""
    if not nums or k <= 0:
        return []
    result = []
    for i in range(len(nums) - k):
        result.append(max(nums[i:i+k]))
    return result

if __name__ == "__main__":
    print(max_in_window([1, 3, -1, -3, 5, 3, 6, 7], 3))
