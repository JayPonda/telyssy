import 'package:t/t.dart' as t;

/// Represents a Telegram user.
class TeliUser {
  final int id;
  final String? firstName;
  final String? lastName;
  final String? username;
  final String? phone;

  const TeliUser({
    required this.id,
    this.firstName,
    this.lastName,
    this.username,
    this.phone,
  });

  factory TeliUser.fromRaw(t.UserBase raw) {
    return switch (raw) {
      t.User u => TeliUser(
          id: u.id,
          firstName: u.firstName,
          lastName: u.lastName,
          username: u.username,
          phone: u.phone,
        ),
      t.UserEmpty u => TeliUser(id: u.id),
      _ => const TeliUser(id: 0),
    };
  }

  @override
  String toString() => 'TeliUser(id: $id, username: $username)';
}
