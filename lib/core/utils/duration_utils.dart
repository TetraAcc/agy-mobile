import '../../models/models.dart';

/// Formats a completed task duration into a concise human-readable label.
String formatTaskDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  if (totalSeconds < 1) return '';
  if (totalSeconds < 60) return '${totalSeconds}s';
  final totalMinutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (totalMinutes < 60) {
    return seconds == 0 ? '${totalMinutes}m' : '${totalMinutes}m ${seconds}s';
  }
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
}

/// Formats an ongoing task elapsed duration as MM:SS or H:MM:SS.
String formatLiveElapsed(Duration duration) {
  final safeSeconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  final seconds = safeSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$mm:$ss';
  }
  return '$mm:$ss';
}

DateTime? _parseTimestamp(String raw) {
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return null;
  return DateTime.tryParse(cleaned);
}

bool _isStandaloneVisibleAi(AgentMessage m) {
  if (m.content.trim().isNotEmpty) return true;
  if (m.status == 'WAITING_APPROVAL' || m.status == 'WAITING_INPUT') return true;
  return m.toolCalls.any((t) => t.name == 'ask_question');
}

/// Computes elapsed turn durations keyed by the last visible AI message index of each turn.
Map<int, Duration> computeTurnDurationsByMsgIdx(List<AgentMessage> messages) {
  if (messages.isEmpty) return const <int, Duration>{};
  final result = <int, Duration>{};
  var i = 0;
  while (i < messages.length) {
    if (messages[i].isUser) {
      i++;
      continue;
    }
    final startIdx = i;
    while (i + 1 < messages.length && !messages[i + 1].isUser) {
      i++;
    }
    final endIdx = i;

    if (startIdx > 0 && messages[startIdx - 1].isUser) {
      final startTime = _parseTimestamp(messages[startIdx - 1].timestamp);
      if (startTime != null) {
        DateTime? endTime;
        for (var k = endIdx; k >= startIdx; k--) {
          final parsed = _parseTimestamp(messages[k].timestamp);
          if (parsed != null) {
            endTime = parsed;
            break;
          }
        }
        if (endTime != null) {
          final diff = endTime.difference(startTime);
          if (diff.inSeconds >= 1) {
            var targetIdx = endIdx;
            for (var k = endIdx; k >= startIdx; k--) {
              if (_isStandaloneVisibleAi(messages[k])) {
                targetIdx = k;
                break;
              }
            }
            result[targetIdx] = diff;
          }
        }
      }
    }
    i++;
  }
  return result;
}

/// Finds the start timestamp of the latest active user turn.
DateTime? findActiveTurnStartTime(List<AgentMessage> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i].isUser) {
      final parsed = _parseTimestamp(messages[i].timestamp);
      if (parsed != null) return parsed;
      break;
    }
  }
  for (var i = messages.length - 1; i >= 0; i--) {
    final parsed = _parseTimestamp(messages[i].timestamp);
    if (parsed != null) return parsed;
  }
  return null;
}
