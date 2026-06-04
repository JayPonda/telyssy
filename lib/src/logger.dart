import 'package:logger/logger.dart';

class _TimestampPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) {
    final now = DateTime.now();
    final ts = '${now.year}-${_p2(now.month)}-${_p2(now.day)} '
        '${_p2(now.hour)}:${_p2(now.minute)}:${_p2(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final label = event.level.name.toUpperCase().padRight(5);
    final color = _colorFor(event.level);
    final line = StringBuffer('${color('[$ts] [$label]')} ${event.message}');
    if (event.error != null) {
      line.writeln();
      line.write(event.error);
    }
    if (event.stackTrace != null) {
      line.writeln();
      line.write(event.stackTrace);
    }
    return [line.toString()];
  }

  // ignore_for_file: deprecated_member_use

  static AnsiColor _colorFor(Level level) {
    switch (level) {
      case Level.all:
      case Level.verbose:
      case Level.trace:
      case Level.debug:
        return const AnsiColor.fg(8);
      case Level.info:
        return const AnsiColor.fg(2);
      case Level.warning:
        return const AnsiColor.fg(3);
      case Level.error:
      case Level.wtf:
      case Level.fatal:
        return const AnsiColor.fg(1);
      case Level.off:
      case Level.nothing:
        return const AnsiColor.none();
    }
  }

  static String _p2(int v) => v.toString().padLeft(2, '0');
}

final Logger log = Logger(
  printer: _TimestampPrinter(),
  level: Level.debug,
);
