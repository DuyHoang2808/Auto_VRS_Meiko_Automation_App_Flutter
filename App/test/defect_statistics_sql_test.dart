// Kiểm chứng truy vấn thống kê loại lỗi trên SQLite THẬT.
//
// Ba thứ dễ sai và chỉ đọc code thì không chắc được:
//   1. Lọc theo lô có thật sự lọc không (bản cũ không có WHERE nào, mọi lô ra
//      cùng một con số tổng của toàn bộ DB).
//   2. Gom theo `ai_type` chứ không phải `type` - `type` là mã SỐ thô của AOI.
//   3. Lỗi chưa phán định phải vào nhóm "chưa soi", không được biến mất khỏi
//      tổng (biến mất thì người xem tưởng lô đã soi hết).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:autovrs_app/services/local_database_service.dart'
    show kUnjudgedDefectKey;

/// DB tối thiểu đủ để chạy truy vấn thống kê: 2 lô, mỗi lô 1 board.
Future<Database> openStatsDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE tbBoard (
      id_board INTEGER PRIMARY KEY AUTOINCREMENT,
      tbLotid_lot INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE tbDefect (
      id_defect INTEGER PRIMARY KEY AUTOINCREMENT,
      type TEXT,
      ai_type TEXT,
      judgement TEXT,
      tbBoardid_board INTEGER
    )
  ''');
  await db.insert('tbBoard', {'id_board': 1, 'tbLotid_lot': 100});
  await db.insert('tbBoard', {'id_board': 2, 'tbLotid_lot': 200});

  Future<void> defect(int board, String? aoiType, String? aiType) =>
      db.insert('tbDefect', {
        'type': aoiType,
        'ai_type': aiType,
        'judgement': aiType == null ? null : 'NG',
        'tbBoardid_board': board,
      });

  // Lô 100: 2 chạm kim, 1 xước, 1 chưa soi. AOI ghi `type` là mã SỐ.
  await defect(1, '2', 'chamkim');
  await defect(1, '5', 'chamkim');
  await defect(1, '2', 'xuoc');
  await defect(1, '7', null); // chưa phán định
  // Lô 200: 1 dị vật - không được lẫn sang thống kê của lô 100.
  await defect(2, '3', 'divat');
  return db;
}

/// Bản sao truy vấn của LocalDatabaseService.getDefectStatistics.
Future<Map<String, int>> defectStats(Database db, {int? idLot}) async {
  const typeExpr = "COALESCE(NULLIF(TRIM(d.ai_type), ''), ?) AS defect_type";
  final results = idLot == null
      ? await db.rawQuery('''
          SELECT $typeExpr, COUNT(*) AS count
          FROM tbDefect d
          GROUP BY defect_type
          ORDER BY count DESC
        ''', [kUnjudgedDefectKey])
      : await db.rawQuery('''
          SELECT $typeExpr, COUNT(*) AS count
          FROM tbDefect d
          JOIN tbBoard b ON d.tbBoardid_board = b.id_board
          WHERE b.tbLotid_lot = ?
          GROUP BY defect_type
          ORDER BY count DESC
        ''', [kUnjudgedDefectKey, idLot]);

  return {
    for (final row in results)
      row['defect_type'].toString(): row['count'] as int,
  };
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('lọc đúng theo lô - lỗi của lô khác không được đếm', () async {
    final db = await openStatsDb();
    addTearDown(db.close);

    final lot100 = await defectStats(db, idLot: 100);
    expect(lot100['chamkim'], 2);
    expect(lot100['xuoc'], 1);
    expect(
      lot100.containsKey('divat'),
      isFalse,
      reason: 'divat thuộc lô 200, không được lọt vào thống kê lô 100',
    );

    final lot200 = await defectStats(db, idLot: 200);
    expect(lot200['divat'], 1);
    expect(lot200.containsKey('chamkim'), isFalse);
  });

  test('không truyền lô -> gộp tất cả các lô', () async {
    final db = await openStatsDb();
    addTearDown(db.close);

    final all = await defectStats(db);
    expect(all['chamkim'], 2);
    expect(all['xuoc'], 1);
    expect(all['divat'], 1, reason: 'phải gộp cả lô 200');
  });

  test('gom theo ai_type, KHÔNG theo mã số thô của AOI', () async {
    final db = await openStatsDb();
    addTearDown(db.close);

    final lot100 = await defectStats(db, idLot: 100);
    // 2 lỗi chạm kim có `type` khác nhau ("2" và "5") nhưng cùng ai_type ->
    // phải gộp thành 1 nhóm. Gom theo `type` sẽ ra 2 nhóm tên "2" và "5".
    expect(lot100['chamkim'], 2);
    expect(lot100.containsKey('2'), isFalse);
    expect(lot100.containsKey('5'), isFalse);
  });

  test('lỗi chưa phán định vào nhóm "chưa soi", không bị mất khỏi tổng', () async {
    final db = await openStatsDb();
    addTearDown(db.close);

    final lot100 = await defectStats(db, idLot: 100);
    expect(lot100[kUnjudgedDefectKey], 1);
    // Tổng phải khớp số lỗi thật của lô, nếu không người xem tưởng đã soi hết.
    final total = lot100.values.fold<int>(0, (s, v) => s + v);
    expect(total, 4);
  });

  test('ai_type rỗng / toàn khoảng trắng cũng tính là chưa soi', () async {
    final db = await openStatsDb();
    addTearDown(db.close);

    await db.insert('tbDefect', {
      'type': '9',
      'ai_type': '',
      'tbBoardid_board': 1,
    });
    await db.insert('tbDefect', {
      'type': '9',
      'ai_type': '   ',
      'tbBoardid_board': 1,
    });

    final lot100 = await defectStats(db, idLot: 100);
    expect(
      lot100[kUnjudgedDefectKey],
      3,
      reason: 'NULL + chuỗi rỗng + khoảng trắng phải cùng một nhóm',
    );
  });

  test('lô không có lỗi nào -> map rỗng, không throw', () async {
    final db = await openStatsDb();
    addTearDown(db.close);
    expect(await defectStats(db, idLot: 999), isEmpty);
  });
}
