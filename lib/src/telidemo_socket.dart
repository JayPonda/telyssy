import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:tg/tg.dart' as tg;

class TeliDemoSocket extends tg.SocketAbstraction {
  TeliDemoSocket(this.socket) : receiver = socket.asBroadcastStream();

  final Socket socket;

  @override
  final Stream<Uint8List> receiver;

  @override
  Future<void> send(List<int> data) async {
    socket.add(data);
    await socket.flush();
  }
}
