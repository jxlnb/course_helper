String formatRelativeTime(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);

  if (diff.inMinutes < 1) {
    return '刚刚';
  } else if (diff.inMinutes < 60) {
    return '${diff.inMinutes}分钟前';
  } else if (diff.inHours < 24) {
    return '${diff.inHours}小时前';
  } else {
    return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
