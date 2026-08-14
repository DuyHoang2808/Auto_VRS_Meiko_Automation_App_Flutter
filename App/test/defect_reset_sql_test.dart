// Kiểm chứng trên SQLite THẬT (sqflite_common_ffi) hai thứ dễ sai mà chỉ đọc
// code thì không chắc được:
//   1. Migration thêm cột `ai_type` chạy đúng trên DB cũ đã có dữ liệu.
//   2. Xoá phán định để soi lại từ đầu KHÔNG làm mất loại lỗi gốc của AOI.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tạo tbDefect theo schema CŨ (chưa có ai_type) + dữ liệu như AOI_Ingest ghi:
/// có `type`, KHÔNG có `judgement`.
Future<Database> openLegacyDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE tbBoard (
      id_board INTEGER PRIMARY KEY AUTOINCREMENT,
      status TEXT DEFAULT 'pending',
      completed_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE tbDefect (
      id_defect INTEGER PRIMARY KEY AUTOINCREMENT,
      type TEXT,
      judgement TEXT,
      time TEXT,
      tbBoardid_board INTEGER
    )
  ''');
  await db.insert('tbBoard', {'id_board': 7, 'status': 'pending'});
  // AOI_Ingest chèn không kèm judgement -> NULL
  await db.insert('tbDefect', {
    'type': 'chamkim',
    'tbBoardid_board': 7,
  });
  await db.insert('tbDefect', {
    'type': 'thieudong',
    'tbBoardid_board': 7,
  });
  return db;
}

/// Bản sao của migration trong LocalDatabaseService._migrateDatabase.
Future<void> migrateAddAiType(Database db) async {
  final info = await db.rawQuery('PRAGMA table_info(tbDefect)');
  if (!info.any((c) => c['name'] == 'ai_type')) {
    await db.execute('ALTER TABLE tbDefect ADD COLUMN ai_type TEXT');
  }
}

/// Bản sao của LocalDatabaseService.resetBoardForReinspection.
Future<void> resetBoard(Database db, int idBoard) async {
  await db.transaction((txn) async {
    await txn.update(
      'tbDefect',
      {'judgement': null, 'ai_type': null, 'time': null},
      where: 'tbBoardid_board = ?',
      whereArgs: [idBoard],
    );
    await txn.update(
      'tbBoard',
      {'status': 'pending', 'completed_at': null},
      where: 'id_board = ?',
      whereArgs: [idBoard],
    );
  });
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('migration thêm ai_type trên DB cũ, giữ nguyên dữ liệu sẵn có', () async {
    final db = await openLegacyDb();
    addTearDown(db.close);

    await migrateAddAiType(db);

    final cols = (await db.rawQuery('PRAGMA table_info(tbDefect)'))
        .map((c) => c['name'])
        .toList();
    expect(cols, contains('ai_type'));
    expect(cols, contains('type'));

    final rows = await db.query('tbDefect', orderBy: 'id_defect ASC');
    expect(rows.length, 2);
    // Loại lỗi AOI còn nguyên, ai_type mặc định NULL
    expect(rows[0]['type'], 'chamkim');
    expect(rows[0]['ai_type'], isNull);
    // Lỗi mới từ AOI phải là "chưa phán định"
    expect(rows[0]['judgement'], isNull);
  });

  test('migration chạy lại lần nữa không lỗi (idempotent)', () async {
    final db = await openLegacyDb();
    addTearDown(db.close);
    await migrateAddAiType(db);
    await migrateAddAiType(db); // không được throw
    final cols = (await db.rawQuery('PRAGMA table_info(tbDefect)'))
        .where((c) => c['name'] == 'ai_type');
    expect(cols.length, 1, reason: 'không được thêm cột trùng');
  });

  test(
    'soi lại từ đầu: xoá phán định + ai_type nhưng GIỮ loại lỗi gốc AOI',
    () async {
      final db = await openLegacyDb();
      addTearDown(db.close);
      await migrateAddAiType(db);

      // Giả lập đã soi xong cả board: auto ghi ai_type + judgement.
      await db.update(
        'tbDefect',
        {'judgement': 'OK', 'ai_type': 'none', 'time': '2026-08-06T10:00:00'},
        where: 'id_defect = ?',
        whereArgs: [1],
      );
      await db.update(
        'tbDefect',
        {'judgement': 'NG', 'ai_type': 'xuoc', 'time': '2026-08-06T10:01:00'},
        where: 'id_defect = ?',
        whereArgs: [2],
      );
      await db.update(
        'tbBoard',
        {'status': 'completed', 'completed_at': '2026-08-06T10:01:00'},
        where: 'id_board = ?',
        whereArgs: [7],
      );

      await resetBoard(db, 7);

      final rows = await db.query('tbDefect', orderBy: 'id_defect ASC');
      // Phán định bị xoá -> board soi lại được từ lỗi đầu tiên
      expect(rows.every((r) => r['judgement'] == null), isTrue);
      expect(rows.every((r) => r['ai_type'] == null), isTrue);
      expect(rows.every((r) => r['time'] == null), isTrue);
      // Loại lỗi gốc AOI KHÔNG được mất - đây là lý do phải tách cột trước khi
      // làm được tính năng "soi lại từ đầu".
      expect(rows[0]['type'], 'chamkim');
      expect(rows[1]['type'], 'thieudong');

      // Board phải quay về pending, nếu không getNextPendingBoard /
      // getFirstBoardByLotId sẽ lọc bỏ và không bao giờ chọn lại được board này.
      final board = (await db.query(
        'tbBoard',
        where: 'id_board = ?',
        whereArgs: [7],
      )).single;
      expect(board['status'], 'pending');
      expect(board['completed_at'], isNull);
    },
  );

  test('reset không ảnh hưởng board khác', () async {
    final db = await openLegacyDb();
    addTearDown(db.close);
    await migrateAddAiType(db);

    await db.insert('tbBoard', {'id_board': 8, 'status': 'completed'});
    await db.insert('tbDefect', {
      'type': 'divat',
      'judgement': 'NG',
      'ai_type': 'divat',
      'tbBoardid_board': 8,
    });

    await resetBoard(db, 7);

    final other = (await db.query(
      'tbDefect',
      where: 'tbBoardid_board = ?',
      whereArgs: [8],
    )).single;
    expect(other['judgement'], 'NG', reason: 'board 8 không được đụng tới');
    final board8 = (await db.query(
      'tbBoard',
      where: 'id_board = ?',
      whereArgs: [8],
    )).single;
    expect(board8['status'], 'completed');
  });
}
