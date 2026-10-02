import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';

/// 1 lỗi đã được phán định chưa (auto hoặc thủ công đều ghi vào `judgement`).
///
/// AOI_Ingest chèn lỗi mà KHÔNG ghi cột `judgement` (xem `insert_defects` trong
/// aoi_ingest_service.py) nên lỗi mới luôn có `judgement IS NULL`. Đây là nguồn
/// sự thật để biết soi tới đâu - thay cho biến đếm trong state của widget, vốn
/// mất sạch khi màn hình bị dispose lúc chuyển tab.
bool isDefectJudged(Map<String, dynamic> defect) {
  final j = defect['judgement']?.toString().trim();
  return j != null && j.isNotEmpty;
}

/// Vị trí lỗi CHƯA phán định đầu tiên, hoặc -1 nếu đã phán định hết.
///
/// Dùng thay cho việc luôn bắt đầu từ index 0: nó tự động bỏ qua các lỗi đã
/// phán định ở lượt trước hoặc do VRS thủ công phán định (kể cả phán định
/// không theo thứ tự, vì màn thủ công cho phép nhảy tới lỗi bất kỳ).
int firstUnjudgedDefectIndex(List<Map<String, dynamic>> defects) {
  return defects.indexWhere((d) => !isDefectJudged(d));
}

/// Loại lỗi để HIỂN THỊ cho người vận hành từ 1 dòng `tbDefect`.
///
/// Ưu tiên `human_type` (loại lỗi CHÍNH NGƯỜI VẬN HÀNH xác nhận khi phán định
/// NG - xem migration human_type), rồi mới tới `ai_type`, fallback `type`.
/// Người vận hành đã tự chọn loại lỗi thì đó là thứ đúng nhất để hiện lại cho
/// họ; nếu vẫn hiện `ai_type` thì họ chọn xong lại thấy đúng nhãn AI đoán sai
/// mà mình vừa sửa.
///
/// Sau `human_type` là `ai_type` (loại lỗi AI nhận định lúc soi), fallback
/// `type`. Lý do thứ tự này:
/// - `ai_type` là kết quả phán định - đúng thứ người vận hành cần thấy trong
///   bảng trạng thái, và `_getDefectDisplayName()` dịch được sang tên tiếng Việt.
/// - `type` là mã SỐ thô do máy AOI xuất ra (`str(type_code)`, ví dụ `"2"`,
///   xem `insert_defects` trong aoi_ingest_service.py) và KHÔNG có bảng ánh xạ
///   sang tên lỗi ở đâu trong hệ thống, nên hiện thẳng ra thì vô nghĩa.
///   Chỉ dùng cho lỗi chưa soi (chưa có `ai_type`).
///
/// Lưu ý: `type` vẫn là nguồn sự thật của AOI trong DB và KHÔNG ai được ghi đè.
/// Hàm này chỉ quyết định *hiển thị*, không quyết định *lưu trữ*.
String? defectTypeForDisplay(Map<String, dynamic> defect) {
  final humanType = defect['human_type']?.toString();
  if (humanType != null && humanType.isNotEmpty) return humanType;
  final aiType = defect['ai_type']?.toString();
  if (aiType != null && aiType.isNotEmpty) return aiType;
  final aoiType = defect['type']?.toString();
  return (aoiType != null && aoiType.isNotEmpty) ? aoiType : null;
}

/// Khoá gom nhóm cho lỗi CHƯA phán định trong thống kê loại lỗi.
///
/// Không loại các lỗi này ra khỏi thống kê: bỏ đi thì tổng trên biểu đồ không
/// còn khớp với số lỗi thật của lô, người xem tưởng đã soi hết.
const String kUnjudgedDefectKey = '__chua_soi__';

class LocalDatabaseService {
  static final LocalDatabaseService _instance =
      LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();

  Database? _db;
  bool _isInitializing = false;

  Future<Database> get database async {
    // Nếu database đã được khởi tạo, trả về ngay
    if (_db != null && _db!.isOpen) {
      return _db!;
    }

    // Nếu đang khởi tạo, đợi
    if (_isInitializing) {
      while (_isInitializing) {
        await Future.delayed(Duration(milliseconds: 10));
      }
      if (_db != null && _db!.isOpen) {
        return _db!;
      }
    }

    // Khởi tạo database
    _isInitializing = true;
    try {
      _db = await _initDatabase();
      return _db!;
    } finally {
      _isInitializing = false;
    }
  }

  Future<Database> _initDatabase() async {
    String path;

    try {
      if (Platform.isWindows) {
        // Sử dụng thư mục Documents của user
        final userProfile =
            Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
        final documentsDir = Directory(
          join(userProfile, 'Documents', 'AutoVRS'),
        );

        // Tạo thư mục nếu không tồn tại
        if (!await documentsDir.exists()) {
          await documentsDir.create(recursive: true);
        }

        path = join(documentsDir.path, 'autovrs.db');
      } else {
        final dbPath = await getDatabasesPath();
        final dbDir = Directory(dirname(join(dbPath, 'autovrs.db')));
        if (!await dbDir.exists()) {
          await dbDir.create(recursive: true);
        }
        path = join(dbPath, 'autovrs.db');
      }

      debugPrint('Database path: $path');

      // If the database file exists but is not writable (e.g., read-only attribute),
      // attempt to create a writable copy and use that instead. This handles cases
      // where the app might be pointing at a bundled/read-only DB.
      final dbFile = File(path);
      if (await dbFile.exists()) {
        debugPrint('📁 Database file exists, checking write permissions...');
        try {
          final raf = await dbFile.open(mode: FileMode.append);
          await raf.close();
          debugPrint('✅ Database file is writable');
        } catch (e) {
          debugPrint(
            '⚠️ Database file not writable ($e). Attempting writable fallback.',
          );
          final dir = dbFile.parent.path;
          final fallbackPath = join(dir, 'autovrs_rw.db');
          final fallbackFile = File(fallbackPath);
          if (!await fallbackFile.exists()) {
            // copy read-only DB to writable copy
            debugPrint('📋 Copying to fallback: $fallbackPath');
            await dbFile.copy(fallbackPath);
            debugPrint('✅ Copied DB to writable fallback: $fallbackPath');
          } else {
            debugPrint('✅ Using existing writable fallback DB: $fallbackPath');
          }
          path = fallbackPath;
        }
      } else {
        debugPrint(
          '📝 Database file does not exist, will be created at: $path',
        );
        // Ensure parent directory is writable
        final dir = dbFile.parent;
        if (!await dir.exists()) {
          await dir.create(recursive: true);
          debugPrint('✅ Created database directory: ${dir.path}');
        }

        // Test if we can write to this directory
        try {
          final testFile = File(join(dir.path, '.write_test'));
          await testFile.writeAsString('test');
          await testFile.delete();
          debugPrint('✅ Directory is writable');
        } catch (e) {
          debugPrint('❌ Directory not writable: $e');
          throw Exception(
            'Cannot write to database directory: ${dir.path}. Error: $e',
          );
        }
      }

      // Try to open database with retry logic for read-only issues
      try {
        return await openDatabase(
          path,
          version: 1,
          onConfigure: _configureDatabase,
          onCreate: _createTables,
          onOpen: (db) async {
            debugPrint('Database opened successfully at $path');
            // Kiểm tra và tạo cột id_model nếu chưa tồn tại
            await _migrateDatabase(db);
          },
          readOnly: false, // ✅ Explicitly set writable mode
          singleInstance: true, // ✅ Prevent multiple instances
        );
      } catch (e) {
        final errMsg = e.toString();
        // If read-only error during open, try fallback immediately
        if (errMsg.toLowerCase().contains('read-only') ||
            errMsg.toLowerCase().contains('read only') ||
            errMsg.toLowerCase().contains('readonly')) {
          debugPrint('⚠️ Database open failed (read-only): $e');
          debugPrint('🔄 Attempting writable fallback database...');

          final dir = dbFile.parent.path;
          final fallbackPath = join(dir, 'autovrs_rw.db');
          debugPrint('📂 Fallback path: $fallbackPath');

          return await openDatabase(
            fallbackPath,
            version: 1,
            onConfigure: _configureDatabase,
            onCreate: _createTables,
            onOpen: (db) async {
              debugPrint('✅ Fallback database opened at $fallbackPath');
              await _migrateDatabase(db);
            },
            readOnly: false,
            singleInstance: true,
          );
        }
        rethrow;
      }
    } catch (e) {
      debugPrint('Error creating database: $e');
      rethrow;
    }
  }

  Future<void> _configureDatabase(Database db) async {
    await db.execute('PRAGMA busy_timeout = 5000');
    await db.execute('PRAGMA journal_mode = WAL');
  }

  Future<void> _migrateDatabase(Database db) async {
    try {
      // Kiểm tra xem cột id_model đã tồn tại trong tbModel chưa
      final info = await db.rawQuery("PRAGMA table_info(tbModel)");
      final hasIdModel = info.any((col) => col['name'] == 'id_model');

      if (!hasIdModel) {
        debugPrint('⚠️ Migration: Adding id_model column to tbModel');
        await db.execute(
          'ALTER TABLE tbModel ADD COLUMN id_model INTEGER PRIMARY KEY',
        );
        debugPrint('✅ Migration completed: id_model column added');
      }

      // Kiểm tra tbLot có cột tbModelid_model chưa
      final lotInfo = await db.rawQuery("PRAGMA table_info(tbLot)");
      final hasTbModelIdModel = lotInfo.any(
        (col) => col['name'] == 'tbModelid_model',
      );

      if (!hasTbModelIdModel) {
        debugPrint('⚠️ Migration: Adding tbModelid_model column to tbLot');
        try {
          await db.execute(
            'ALTER TABLE tbLot ADD COLUMN tbModelid_model INTEGER',
          );
          debugPrint('✅ Migration completed: tbModelid_model column added');
        } catch (e) {
          debugPrint('⚠️ Could not add tbModelid_model to tbLot: $e');
        }
      }

      // Kiểm tra tbLot có cột lot_code chưa - mã lot thật AOI đặt tên cho
      // folder lot (watch_dir/<lot_code>/<board_id>/...), thay cho việc chỉ
      // định danh lot bằng id_lot nội bộ. Migration này đồng bộ với
      // AOI_Ingest/aoi_ingest_service.py::ensure_schema, vốn đã thêm cột này
      // ở phía Python và dùng nó làm khoá get_or_create_lot(model, lot_code).
      // Lot tạo trước migration này sẽ có lot_code = NULL mãi mãi - nơi hiển
      // thị cần fallback cho trường hợp đó.
      final hasLotCode = lotInfo.any((col) => col['name'] == 'lot_code');
      if (!hasLotCode) {
        debugPrint('⚠️ Migration: Adding lot_code column to tbLot');
        try {
          await db.execute('ALTER TABLE tbLot ADD COLUMN lot_code TEXT');
          debugPrint('✅ Migration completed: lot_code column added');
        } catch (e) {
          debugPrint('⚠️ Could not add lot_code to tbLot: $e');
        }
      }

      // Kiểm tra tbBoard có cột tbLotid_lot chưa
      final boardInfo = await db.rawQuery("PRAGMA table_info(tbBoard)");
      final hasTbLotIdLot = boardInfo.any(
        (col) => col['name'] == 'tbLotid_lot',
      );

      if (!hasTbLotIdLot) {
        debugPrint('⚠️ Migration: Adding tbLotid_lot column to tbBoard');
        try {
          await db.execute(
            'ALTER TABLE tbBoard ADD COLUMN tbLotid_lot INTEGER',
          );
          debugPrint('✅ Migration completed: tbLotid_lot column added');
        } catch (e) {
          debugPrint('⚠️ Could not add tbLotid_lot to tbBoard: $e');
        }
      }

      // Kiểm tra tbBoard có cột board_code/layer_id chưa (thêm khi làm
      // AOI_Ingest - mỗi board vật lý AOI quét ra nhiều layer, mỗi layer là
      // 1 dòng tbBoard riêng, phân biệt bằng board_code (mã board AOI, vd
      // "6721") + layer_id ("l1"/"l8"...). Migration này đồng bộ với
      // AOI_Ingest/aoi_ingest_service.py::ensure_schema, vốn đã tự thêm 2
      // cột này ở phía Python từ trước - giờ thêm nốt ở đây để Flutter cũng
      // đọc/dùng được.
      final boardInfoForAoi = await db.rawQuery("PRAGMA table_info(tbBoard)");
      final boardColNamesForAoi = boardInfoForAoi
          .map((col) => col['name'])
          .toSet();

      if (!boardColNamesForAoi.contains('board_code')) {
        debugPrint('⚠️ Migration: Adding board_code column to tbBoard');
        try {
          await db.execute('ALTER TABLE tbBoard ADD COLUMN board_code TEXT');
          debugPrint('✅ Migration completed: board_code column added');
        } catch (e) {
          debugPrint('⚠️ Could not add board_code to tbBoard: $e');
        }
      }
      if (!boardColNamesForAoi.contains('layer_id')) {
        debugPrint('⚠️ Migration: Adding layer_id column to tbBoard');
        try {
          await db.execute('ALTER TABLE tbBoard ADD COLUMN layer_id TEXT');
          debugPrint('✅ Migration completed: layer_id column added');
        } catch (e) {
          debugPrint('⚠️ Could not add layer_id to tbBoard: $e');
        }
      }

      // Kiểm tra tbBoard có cột status/completed_at chưa (cơ chế "board tiếp
      // theo": 'pending' -> 'in_progress' -> 'completed'. SQLite tự điền giá
      // trị DEFAULT cho các dòng đã có sẵn khi ALTER TABLE ADD COLUMN, không
      // chỉ dòng mới, nên board cũ cũng sẽ có status='pending' sau migration).
      if (!boardColNamesForAoi.contains('status')) {
        debugPrint('⚠️ Migration: Adding status column to tbBoard');
        try {
          await db.execute(
            "ALTER TABLE tbBoard ADD COLUMN status TEXT DEFAULT 'pending'",
          );
          debugPrint('✅ Migration completed: status column added');
        } catch (e) {
          debugPrint('⚠️ Could not add status to tbBoard: $e');
        }
      }
      if (!boardColNamesForAoi.contains('completed_at')) {
        debugPrint('⚠️ Migration: Adding completed_at column to tbBoard');
        try {
          await db.execute('ALTER TABLE tbBoard ADD COLUMN completed_at TEXT');
          debugPrint('✅ Migration completed: completed_at column added');
        } catch (e) {
          debugPrint('⚠️ Could not add completed_at to tbBoard: $e');
        }
      }

      // Cột aoi_machine/src_fingerprint: thêm khi làm tính năng "chọn máy
      // AOI" (nhiều máy AOI cùng ghi board vào 1 file autovrs.db dùng chung -
      // xem AOI_Ingest/aoi_ingest_config.yaml). Migration này đồng bộ với
      // AOI_Ingest/aoi_ingest_service.py::ensure_schema, đã tự thêm 2 cột này
      // ở phía Python từ trước.
      //
      // - aoi_machine: tên máy AOI quét ra board đó, dùng để LỌC mọi danh
      //   sách model/lot/board theo đúng máy đang chọn (xem AoiMachineProvider
      //   + các hàm getAllModels/getSelectableLotsForModel/... bên dưới).
      // - src_fingerprint: Flutter KHÔNG dùng cột này (chỉ Python dùng nội bộ
      //   để phát hiện AOI ghi đè thư mục board) - khai báo cho đủ schema,
      //   không có logic gì đi kèm ở đây.
      if (!boardColNamesForAoi.contains('aoi_machine')) {
        debugPrint('⚠️ Migration: Adding aoi_machine column to tbBoard');
        try {
          await db.execute('ALTER TABLE tbBoard ADD COLUMN aoi_machine TEXT');
          // Backfill 1 LẦN DUY NHẤT (chỉ chạy trong nhánh "cột vừa được thêm"
          // - không lặp lại ở lần mở app sau): >45.000 board cũ ghi TRƯỚC khi
          // có cột này đều là aoi_machine=NULL. Theo xác nhận của người vận
          // hành hệ thống (2026-09-23), toàn bộ dữ liệu cũ này thực tế là của
          // máy 'YMZ-1' (máy duy nhất tồn tại trước khi có tính năng nhiều
          // máy) - gán thẳng để MỌI câu lọc theo aoi_machine phía dưới có thể
          // dùng so sánh bằng đơn giản (`aoi_machine = ?`), không cần nhánh
          // xử lý NULL riêng ở bất kỳ đâu.
          final backfilled = await db.rawUpdate(
            "UPDATE tbBoard SET aoi_machine = 'YMZ-1' WHERE aoi_machine IS NULL",
          );
          debugPrint(
            '✅ Migration completed: aoi_machine column added '
            '(backfilled $backfilled board cũ thành YMZ-1)',
          );
        } catch (e) {
          debugPrint('⚠️ Could not add aoi_machine to tbBoard: $e');
        }
      }
      if (!boardColNamesForAoi.contains('src_fingerprint')) {
        debugPrint('⚠️ Migration: Adding src_fingerprint column to tbBoard');
        try {
          await db.execute(
            'ALTER TABLE tbBoard ADD COLUMN src_fingerprint TEXT',
          );
          debugPrint('✅ Migration completed: src_fingerprint column added');
        } catch (e) {
          debugPrint('⚠️ Could not add src_fingerprint to tbBoard: $e');
        }
      }

      // Cột board_side: mặt THẬT (A/B) lấy thẳng từ tên file AOI ghi ra
      // ("A.vrs"/"B.vrs" - xem AOI_Ingest/aoi_ingest_service.py::process_board_once,
      // biến `side = vrs_path.stem`), KHÔNG suy đoán từ layer_id nữa. Trước
      // đây `VRSProvider.boardSideFromLayerId` tự suy mặt từ layer_id (quy
      // ước l1-l4=B/l5-l8=A) - sai với nhiều tên layer AOI thực tế dùng (vd
      // "core_1", "conf_8", "top_p_ok", "bot_p_ok", "l8_dummy") vì không khớp
      // mẫu "l<số>", rơi về mặc định 'B' một cách vô căn cứ (có ca còn sai
      // hướng, vd "bot_p_ok" đáng lẽ là mặt A) - bug thật gặp phải: board có
      // layer_id lạ không bao giờ được coi là có mặt A để chuyển sang. Đồng
      // bộ với AOI_Ingest/aoi_ingest_service.py::ensure_schema. Rows ghi
      // TRƯỚC migration này giữ NULL - VRSProvider.boardSideOf() phải
      // fallback về boardSideFromLayerId cho các dòng đó.
      if (!boardColNamesForAoi.contains('board_side')) {
        debugPrint('⚠️ Migration: Adding board_side column to tbBoard');
        try {
          await db.execute('ALTER TABLE tbBoard ADD COLUMN board_side TEXT');
          debugPrint('✅ Migration completed: board_side column added');
        } catch (e) {
          debugPrint('⚠️ Could not add board_side to tbBoard: $e');
        }
      }

      // Bảng tbBoardBatch: "đợt" board (start_board_code..end_board_code) vận
      // hành viên chọn mỗi lần nạp máy VRS thật (máy chỉ tải được ~100 board
      // mỗi lần, 1 lot có thể có nhiều hơn hẳn con số đó). CREATE TABLE IF NOT
      // EXISTS tự idempotent nên không cần dance kiểm tra tồn tại như các cột
      // phía trên - chạy lại mỗi lần mở DB cũng an toàn.
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS tbBoardBatch (
            id_batch INTEGER PRIMARY KEY AUTOINCREMENT,
            tbLotid_lot INTEGER,
            start_board_code TEXT,
            end_board_code TEXT,
            start_id_board INTEGER,
            end_id_board INTEGER,
            status TEXT DEFAULT 'in_progress',
            created_at TEXT,
            completed_at TEXT,
            FOREIGN KEY (tbLotid_lot) REFERENCES tbLot(id_lot)
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_tbBoardBatch_lot ON tbBoardBatch(tbLotid_lot, start_id_board, end_id_board)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_tbBoard_lot_board ON tbBoard(tbLotid_lot, id_board)',
        );
        debugPrint('✅ Migration completed: tbBoardBatch table ensured');
      } catch (e) {
        debugPrint('⚠️ Could not create tbBoardBatch: $e');
      }

      // tbBoardBatch.aoi_machine: bảng này do Flutter tạo (Python không đụng
      // tới), nên thêm thẳng cột này ở đây thay vì chỉ dựa vào aoi_machine
      // của tbBoard. Lý do: id_board là 1 cột AUTOINCREMENT DÙNG CHUNG cho
      // MỌI máy AOI ghi vào cùng 1 file autovrs.db (xem ghi chú aoi_machine ở
      // tbBoard phía trên), nên khoảng [start_id_board, end_id_board] của 1
      // đợt do máy A tạo hoàn toàn có thể "dính" số id_board của board máy B
      // ghi xen giữa cùng lúc - dù về logic 2 đợt đó không hề chồng nhau. Gắn
      // thẳng aoi_machine vào đợt (thay vì suy luận lại từ board) để mọi so
      // sánh/chồng lấn đợt (rangeOverlapsExistingBatch, getActiveBatchForLot)
      // chỉ xét trong đúng phạm vi 1 máy.
      final batchInfo = await db.rawQuery("PRAGMA table_info(tbBoardBatch)");
      final hasBatchAoiMachine = batchInfo.any(
        (col) => col['name'] == 'aoi_machine',
      );
      if (!hasBatchAoiMachine) {
        debugPrint('⚠️ Migration: Adding aoi_machine column to tbBoardBatch');
        try {
          await db.execute(
            'ALTER TABLE tbBoardBatch ADD COLUMN aoi_machine TEXT',
          );
          // Backfill 1 lần, cùng lý do và cùng giá trị với tbBoard.aoi_machine
          // ở trên - các đợt tạo trước tính năng này đều thuộc máy 'YMZ-1'.
          // Bắt buộc phải backfill (không để NULL) - nếu không, 1 đợt đang dở
          // dang từ trước sẽ "biến mất" khỏi getActiveBatchForLot ngay khi
          // lọc thêm aoi_machine = 'YMZ-1', khiến app tưởng lot chưa có đợt
          // nào và bắt vận hành viên tạo đợt mới dù đang có đợt chạy dở.
          final backfilled = await db.rawUpdate(
            "UPDATE tbBoardBatch SET aoi_machine = 'YMZ-1' WHERE aoi_machine IS NULL",
          );
          debugPrint(
            '✅ Migration completed: tbBoardBatch.aoi_machine column added '
            '(backfilled $backfilled đợt cũ thành YMZ-1)',
          );
        } catch (e) {
          debugPrint('⚠️ Could not add aoi_machine to tbBoardBatch: $e');
        }
      }

      // Kiểm tra tbDefect có cột plc_coor chưa. Cột này lưu tọa độ Board
      // (Gerber/design, CHƯA quy đổi sang PLC — định dạng "x;y", ví dụ
      // "19.887;5.86"). vrs_main_screen.dart và manual_vrs_screen.dart đọc
      // trực tiếp cột này rồi gửi cho gateway (/api/inspect-defect hoặc
      // /api/plc/move_bulech) để tự board_to_plc + bù lệch board trước khi
      // gửi PLC thật — KHÔNG gửi thẳng giá trị này cho PLC.
      final defectInfo = await db.rawQuery("PRAGMA table_info(tbDefect)");
      final hasPlcCoor = defectInfo.any((col) => col['name'] == 'plc_coor');

      if (!hasPlcCoor) {
        debugPrint('⚠️ Migration: Adding plc_coor column to tbDefect');
        try {
          await db.execute('ALTER TABLE tbDefect ADD COLUMN plc_coor TEXT');
          debugPrint('✅ Migration completed: plc_coor column added');
        } catch (e) {
          debugPrint('⚠️ Could not add plc_coor to tbDefect: $e');
        }
      }

      // Cột ai_type: loại lỗi do AI/người vận hành phán định lại khi soi.
      // Trước đây kết quả này bị ghi ĐÈ lên cột `type` (loại lỗi gốc từ AOI),
      // nên mỗi lỗi OK sẽ biến `type` thành 'none' và mất vĩnh viễn loại lỗi
      // AOI báo — làm sai thống kê (getDefectStatistics GROUP BY type) và làm
      // sai request Gerber (dùng defect['type'] làm defectType). Từ nay:
      //   type    = loại lỗi AOI báo, CHỈ AOI_Ingest ghi, không ai ghi đè
      //   ai_type = loại lỗi AI/người vận hành nhận định khi soi
      if (!defectInfo.any((col) => col['name'] == 'ai_type')) {
        debugPrint('⚠️ Migration: Adding ai_type column to tbDefect');
        try {
          await db.execute('ALTER TABLE tbDefect ADD COLUMN ai_type TEXT');
          debugPrint('✅ Migration completed: ai_type column added');
        } catch (e) {
          debugPrint('⚠️ Could not add ai_type to tbDefect: $e');
        }
      }

      // Cột ai_verdict: phán định OK/NG do AI tự đưa ra lúc soi thủ công
      // (VRS Thủ công), lưu ĐỘC LẬP với `judgement` (quyết định CUỐI CÙNG của
      // người vận hành, có thể trùng hoặc lệch với AI). Mục đích: giữ lại vết
      // AI dự đoán gì để sau này so sánh/đánh giá độ chính xác AI, mà không
      // lẫn với `judgement` vốn là nguồn sự thật cho mọi thống kê NG rate.
      if (!defectInfo.any((col) => col['name'] == 'ai_verdict')) {
        debugPrint('⚠️ Migration: Adding ai_verdict column to tbDefect');
        try {
          await db.execute('ALTER TABLE tbDefect ADD COLUMN ai_verdict TEXT');
          debugPrint('✅ Migration completed: ai_verdict column added');
        } catch (e) {
          debugPrint('⚠️ Could not add ai_verdict to tbDefect: $e');
        }
      }

      // Cột human_type: LOẠI LỖI do chính người vận hành xác nhận khi phán
      // định NG ở VRS Thủ công - nhãn chuẩn (ground truth) để sau này huấn
      // luyện/đánh giá lại mô hình AI. Tách riêng khỏi `ai_type` (loại lỗi do
      // AI đoán) đúng như `judgement` tách khỏi `ai_verdict`: trộn chung thì
      // không còn phân biệt được nhãn nào người xác nhận, nhãn nào máy đoán -
      // tức mất hết giá trị làm dữ liệu huấn luyện.
      //
      // Lưu TÊN LỚP CHUẨN của mô hình (vd 'DiVat'), KHÔNG phải tên hiển thị
      // tiếng Việt ('Di Vat') - xem kDefectClassNames trong
      // ai_detection_service.dart. `ai_type` cũ đang lẫn cả 2 cách viết cho
      // cùng 1 loại lỗi (dữ liệu thật: 'DiVat' 15 dòng + 'Di Vat' 15 dòng),
      // làm thống kê loại lỗi bị tách đôi - không lặp lại lỗi đó ở cột này.
      if (!defectInfo.any((col) => col['name'] == 'human_type')) {
        debugPrint('⚠️ Migration: Adding human_type column to tbDefect');
        try {
          await db.execute('ALTER TABLE tbDefect ADD COLUMN human_type TEXT');
          debugPrint('✅ Migration completed: human_type column added');
        } catch (e) {
          debugPrint('⚠️ Could not add human_type to tbDefect: $e');
        }
      }

      final updatedDefectInfo = await db.rawQuery(
        "PRAGMA table_info(tbDefect)",
      );
      Map<String, Object?>? urlImageColumn;
      for (final column in updatedDefectInfo) {
        if (column['name'] == 'url_image') {
          urlImageColumn = column;
          break;
        }
      }
      final urlImageType = (urlImageColumn?['type'] ?? '')
          .toString()
          .toUpperCase();

      if (urlImageColumn == null) {
        debugPrint('Migration: Adding url_image TEXT column to tbDefect');
        await db.execute('ALTER TABLE tbDefect ADD COLUMN url_image TEXT');
      } else if (urlImageType != 'TEXT') {
        debugPrint(
          'Migration: Rebuilding tbDefect to convert url_image from $urlImageType to TEXT',
        );
        await _rebuildTbDefectWithTextUrlImage(db);
        debugPrint('Migration completed: url_image converted to TEXT');
      }
    } catch (e) {
      debugPrint('⚠️ Migration warning (non-critical): $e');
      // Không throw - cho phép app tiếp tục chạy
    }
  }

  Future<void> _rebuildTbDefectWithTextUrlImage(Database db) async {
    await db.transaction((txn) async {
      await txn.execute('DROP TABLE IF EXISTS tbDefect_new');
      await txn.execute('''
        CREATE TABLE tbDefect_new (
          id_defect INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT,
          ai_type TEXT,
          judgement TEXT,
          height REAL,
          width REAL,
          time TEXT,
          coordinates TEXT,
          url_image TEXT,
          tbBoardid_board INTEGER,
          plc_coor TEXT,
          ai_verdict TEXT,
          human_type TEXT,
          FOREIGN KEY (tbBoardid_board) REFERENCES tbBoard(id_board)
        )
      ''');

      await txn.execute('''
        INSERT INTO tbDefect_new (
          id_defect,
          type,
          ai_type,
          judgement,
          height,
          width,
          time,
          coordinates,
          url_image,
          tbBoardid_board,
          plc_coor,
          ai_verdict,
          human_type
        )
        SELECT
          id_defect,
          type,
          ai_type,
          judgement,
          height,
          width,
          time,
          coordinates,
          CASE
            WHEN url_image IS NULL THEN NULL
            ELSE CAST(url_image AS TEXT)
          END,
          tbBoardid_board,
          plc_coor,
          ai_verdict,
          human_type
        FROM tbDefect
      ''');

      await txn.execute('DROP TABLE tbDefect');
      await txn.execute('ALTER TABLE tbDefect_new RENAME TO tbDefect');
    });
  }

  Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tbModel (
        id_model INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        line_size REAL,
        space_size REAL,
        url_gerber TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS tbLot (
        id_lot INTEGER PRIMARY KEY AUTOINCREMENT,
        NG_rate REAL,
        fakeDef REAL,
        board_quantity INTEGER,
        tbModelid_model INTEGER,
        FOREIGN KEY (tbModelid_model) REFERENCES tbModel(id_model)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS tbBoard (
        id_board INTEGER PRIMARY KEY AUTOINCREMENT,
        defect_quantity INTEGER,
        erro_quantity INTEGER,
        tbLotid_lot INTEGER,
        board_code TEXT,
        layer_id TEXT,
        status TEXT DEFAULT 'pending',
        completed_at TEXT,
        aoi_machine TEXT,
        src_fingerprint TEXT,
        board_side TEXT,
        FOREIGN KEY (tbLotid_lot) REFERENCES tbLot(id_lot)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS tbBoardBatch (
        id_batch INTEGER PRIMARY KEY AUTOINCREMENT,
        tbLotid_lot INTEGER,
        start_board_code TEXT,
        end_board_code TEXT,
        start_id_board INTEGER,
        end_id_board INTEGER,
        status TEXT DEFAULT 'in_progress',
        created_at TEXT,
        completed_at TEXT,
        aoi_machine TEXT,
        FOREIGN KEY (tbLotid_lot) REFERENCES tbLot(id_lot)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tbBoardBatch_lot ON tbBoardBatch(tbLotid_lot, start_id_board, end_id_board)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tbBoard_lot_board ON tbBoard(tbLotid_lot, id_board)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS tbDefect (
        id_defect INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT,
        ai_type TEXT,
        judgement TEXT,
        height REAL,
        width REAL,
        time TEXT,
        coordinates TEXT,
        url_image TEXT,
        tbBoardid_board INTEGER,
        plc_coor TEXT,
        ai_verdict TEXT,
        human_type TEXT,
        FOREIGN KEY (tbBoardid_board) REFERENCES tbBoard(id_board)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS tbConfig (
        config_key TEXT PRIMARY KEY,
        config_value TEXT
      )
    ''');

    debugPrint('Database tables created successfully');
  }

  Future<String> get databasePath async {
    if (Platform.isWindows) {
      final userProfile =
          Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
      final documentsDir = Directory(join(userProfile, 'Documents', 'AutoVRS'));
      return join(documentsDir.path, 'autovrs.db');
    } else {
      final dbPath = await getDatabasesPath();
      return join(dbPath, 'autovrs.db');
    }
  }

  // ========== AOI MACHINE OPERATIONS ==========
  //
  // Nhiều máy AOI (mỗi máy 1 instance AOI_Ingest riêng) có thể cùng ghi board
  // vào 1 file autovrs.db dùng chung - xem AOI_Ingest/aoi_ingest_config.yaml
  // và AoiMachineProvider. Toàn bộ danh sách model/lot/board ở dưới cần được
  // lọc theo đúng máy vận hành viên đang chọn.

  /// Gợi ý tên máy AOI đã từng ghi dữ liệu, cho màn chọn máy (xem
  /// AoiMachineDialog) - CỘNG với cho phép gõ tay (máy mới lắp, chưa có
  /// board nào, sẽ không xuất hiện ở đây). Tên phải khớp CHÍNH XÁC giá trị
  /// `aoi_machine` trong aoi_ingest_config.yaml của máy đó.
  Future<List<String>> getKnownAoiMachines() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT DISTINCT aoi_machine FROM tbBoard
      WHERE aoi_machine IS NOT NULL AND aoi_machine != ''
      ORDER BY aoi_machine ASC
    ''');
    return rows
        .map((r) => r['aoi_machine']?.toString())
        .whereType<String>()
        .toList();
  }

  // ========== MODEL OPERATIONS ==========
  Future<int> insertModel(Map<String, dynamic> model) async {
    final db = await database;
    final idModel = await db.insert(
      'tbModel',
      model,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return idModel;
  }

  /// Danh sách mã hàng (model) hiện cho màn "Cài đặt Model" - CHỈ hiện model
  /// có board thuộc máy [aoiMachine] đang chọn, HOẶC model CHƯA có board nào
  /// cả (model vừa tạo ở add_model_screen.dart chưa có board - phải vẫn hiện
  /// ra, nếu không operator tưởng tạo model bị lỗi/mất tích).
  ///
  /// tbModel KHÔNG có khái niệm "thuộc máy nào" - 1 mã hàng dùng chung cho
  /// mọi máy AOI, chỉ board (qua lot) mới gắn với 1 máy cụ thể - nên lọc bằng
  /// EXISTS qua tbLot -> tbBoard, không lọc thẳng cột nào của tbModel.
  ///
  /// [aoiMachine] null = không lọc gì (trả về mọi model, hành vi cũ) - chỉ
  /// nên xảy ra khi gọi trước lúc chọn máy (không có màn nào thật sự dùng
  /// đường này - SelectModelScreen luôn bắt chọn máy trước khi tải danh sách).
  Future<List<Map<String, dynamic>>> getAllModels({String? aoiMachine}) async {
    final db = await database;
    if (aoiMachine == null) {
      return await db.query('tbModel');
    }
    return await db.rawQuery(
      '''
      SELECT * FROM tbModel m
      WHERE NOT EXISTS (
          SELECT 1 FROM tbBoard b
          JOIN tbLot l ON l.id_lot = b.tbLotid_lot
          WHERE l.tbModelid_model = m.id_model
        )
        OR EXISTS (
          SELECT 1 FROM tbBoard b
          JOIN tbLot l ON l.id_lot = b.tbLotid_lot
          WHERE l.tbModelid_model = m.id_model AND b.aoi_machine = ?
        )
      ORDER BY m.id_model
      ''',
      [aoiMachine],
    );
  }

  /// Delete a model by its id_model. Returns number of rows deleted.
  Future<int> deleteModel(int id) async {
    final db = await database;
    return await db.delete('tbModel', where: 'id_model = ?', whereArgs: [id]);
  }

  /// Update line_size/space_size (+ url_gerber nếu truyền vào) của 1 model.
  /// Returns number of rows updated.
  ///
  /// `urlGerber`: đường dẫn đầy đủ tới thư mục job QCamber thật - dùng khi
  /// tên mã hàng (`name`) không trùng tên thư mục job (xem
  /// QCamberGerberService.resolveJobName). Truyền `null` để KHÔNG đụng tới
  /// cột này (giữ nguyên giá trị cũ); truyền chuỗi rỗng để xoá cấu hình,
  /// quay về dùng `name` làm tên job như mặc định.
  Future<int> updateModelSizes(
    int idModel, {
    required double lineSize,
    required double spaceSize,
    String? urlGerber,
  }) async {
    final db = await database;
    final values = <String, dynamic>{
      'line_size': lineSize,
      'space_size': spaceSize,
    };
    if (urlGerber != null) values['url_gerber'] = urlGerber;
    return await db.update(
      'tbModel',
      values,
      where: 'id_model = ?',
      whereArgs: [idModel],
    );
  }

  Future<Map<String, dynamic>?> getModelById(int id) async {
    final db = await database;
    final results = await db.query(
      'tbModel',
      where: 'id_model = ?',
      whereArgs: [id],
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<Map<String, dynamic>?> getActiveModel() async {
    final db = await database;
    // Just return the first model for now since there's no is_active column
    final results = await db.query('tbModel', limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  // ========== LOT OPERATIONS ==========
  Future<int> insertLot(Map<String, dynamic> lot) async {
    final db = await database;
    return await db.insert(
      'tbLot',
      lot,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAllLots() async {
    final db = await database;
    return await db.query('tbLot', orderBy: 'id_lot DESC');
  }

  Future<Map<String, dynamic>?> getLotById(int idLot) async {
    final db = await database;
    final results = await db.query(
      'tbLot',
      where: 'id_lot = ?',
      whereArgs: [idLot],
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// Xóa 1 lot cùng toàn bộ dữ liệu con của nó (tbDefect/tbBoardBatch/tbBoard)
  /// - sqlite ở đây không bật PRAGMA foreign_keys nên không tự cascade, phải
  /// xóa tay theo thứ tự con trước cha. Trả về số dòng tbLot đã xóa (0 hoặc 1).
  ///
  /// [aoiMachine]: 1 dòng tbLot có thể bị NHIỀU máy AOI dùng chung (lot_code
  /// chỉ là ngày - xem AoiMachineProvider) - nếu không kiểm tra, vận hành
  /// viên máy A bấm "Xóa lô" tưởng đang xóa dữ liệu của máy mình sẽ xóa LUÔN
  /// board/lỗi của máy B đang dùng chung lot đó (hành động không thể hoàn
  /// tác). Truyền [aoiMachine] để CHẶN xóa nếu lot có board của máy khác -
  /// ném [StateError] với thông báo rõ thay vì âm thầm xóa nhầm. Truyền
  /// `null` để bỏ qua kiểm tra này (giữ hành vi cũ - KHÔNG dùng cho bất kỳ
  /// màn hình vận hành nào sau khi có tính năng nhiều máy).
  Future<int> deleteLot(int idLot, {String? aoiMachine}) async {
    final db = await database;
    return await db.transaction((txn) async {
      if (aoiMachine != null) {
        final otherMachine = await txn.rawQuery(
          '''
          SELECT DISTINCT aoi_machine FROM tbBoard
          WHERE tbLotid_lot = ? AND (aoi_machine IS NULL OR aoi_machine != ?)
          LIMIT 1
          ''',
          [idLot, aoiMachine],
        );
        if (otherMachine.isNotEmpty) {
          final otherName = otherMachine.first['aoi_machine']?.toString();
          throw StateError(
            'Lô này có board thuộc máy khác'
            '${otherName != null ? ' ("$otherName")' : ' (chưa xác định)'} '
            '- không thể xóa cả lô vì sẽ xóa nhầm dữ liệu của máy đó. '
            'Hãy dùng "Quản lý board" để xóa từng board riêng của máy '
            '"$aoiMachine" đang chọn.',
          );
        }
      }

      await txn.delete(
        'tbDefect',
        where:
            'tbBoardid_board IN (SELECT id_board FROM tbBoard WHERE tbLotid_lot = ?)',
        whereArgs: [idLot],
      );
      await txn.delete(
        'tbBoardBatch',
        where: 'tbLotid_lot = ?',
        whereArgs: [idLot],
      );
      await txn.delete('tbBoard', where: 'tbLotid_lot = ?', whereArgs: [idLot]);
      return await txn.delete('tbLot', where: 'id_lot = ?', whereArgs: [idLot]);
    });
  }

  // ========== BOARD OPERATIONS ==========
  Future<int> insertBoard(Map<String, dynamic> board) async {
    final db = await database;
    return await db.insert(
      'tbBoard',
      board,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAllBoards() async {
    final db = await database;
    return await db.query('tbBoard', orderBy: 'id_board DESC');
  }

  Future<List<Map<String, dynamic>>> getBoardsByLot(int idLot) async {
    final db = await database;
    return await db.query(
      'tbBoard',
      where: 'tbLotid_lot = ?',
      whereArgs: [idLot],
      orderBy: 'id_board DESC',
    );
  }

  Future<Map<String, dynamic>?> getBoardById(int idBoard) async {
    final db = await database;
    final results = await db.query(
      'tbBoard',
      where: 'id_board = ?',
      whereArgs: [idBoard],
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// Xoá hết phán định của 1 board để kiểm tra lại từ đầu ("Board đã bị động,
  /// calib lại" / "Kiểm tra lại từ đầu").
  ///
  /// Cần thiết vì tiến độ được suy ra từ `judgement`: nếu không xoá thì
  /// "soi lại từ đầu" sẽ vẫn nhảy tới lỗi chưa phán định đầu tiên, tức không
  /// soi lại gì cả. Đồng thời đưa board về 'pending' vì `getNextPendingBoard`
  /// và `getFirstBoardByLotId` đều lọc bỏ board 'completed' - không reset thì
  /// board đã hoàn tất sẽ không bao giờ chọn lại được.
  ///
  /// CHỈ xoá `judgement` (+ `ai_type`, `human_type`, `ai_verdict`, `time`):
  /// `type` là loại lỗi gốc do AOI ghi nên phải giữ nguyên. `human_type` phải
  /// xoá cùng `judgement` - giữ lại nhãn loại lỗi của lượt soi trước trong khi
  /// phán định đã bị xoá sẽ tạo ra nhãn huấn luyện không ai xác nhận.
  Future<void> resetBoardForReinspection(int idBoard) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.update(
        'tbDefect',
        {
          'judgement': null,
          'ai_type': null,
          'human_type': null,
          'ai_verdict': null,
          'time': null,
        },
        where: 'tbBoardid_board = ?',
        whereArgs: [idBoard],
      );
      await txn.update(
        'tbBoard',
        {'status': 'pending', 'completed_at': null},
        where: 'id_board = ?',
        whereArgs: [idBoard],
      );
      debugPrint(
        '♻️ Reset board $idBoard de kiem tra lai: xoa phan dinh cua $rows loi',
      );
    });
  }

  /// Đánh dấu 1 board đã xử lý xong (hết lỗi, đã judgement). Dùng bởi
  /// VRSProvider.completeCurrentBoardAndCheckNext() để biết board nào đã
  /// xong khi tìm board tiếp theo trong cùng lot.
  Future<int> markBoardCompleted(int idBoard) async {
    final db = await database;
    return await db.update(
      'tbBoard',
      {'status': 'completed', 'completed_at': DateTime.now().toIso8601String()},
      where: 'id_board = ?',
      whereArgs: [idBoard],
    );
  }

  /// Lấy board tiếp theo trong cùng lot [idLot] mà chưa hoàn tất, theo THỨ
  /// TỰ SỐ board_code tăng dần - KHÔNG phải theo id_board (xem ghi chú dài ở
  /// getFirstBoardByLotId về vì sao 2 thứ tự này có thể khác nhau: id_board
  /// là thứ tự AOI_Ingest ghi vào DB, không đảm bảo trùng board_code tăng
  /// dần). So sánh theo cặp (board_code, id_board) - lớn hơn cặp
  /// ([afterBoardCode], [afterBoardId]) hiện tại - vì board_code không unique
  /// trong 1 lot (1 board vật lý có nhiều dòng layer/mặt cùng board_code):
  /// dùng id_board làm tie-break để vẫn lấy đúng dòng layer kế tiếp của CÙNG
  /// board trước khi nhảy sang board_code khác.
  ///
  /// [afterBoardCode] có thể null (board cũ trước AOI_Ingest chưa có
  /// board_code) - khi đó coi như 0, để không loại board hợp lệ nào ra khỏi
  /// kết quả. Board có board_code null sẽ không được tìm thấy bởi hàm này
  /// (CAST(NULL AS INTEGER) không so sánh lớn hơn được) - chấp nhận được vì
  /// đây là dữ liệu cũ trước AOI_Ingest, đã biết là trường hợp rìa chưa xử lý
  /// riêng (xem ghi chú "board_code NULL xen kẽ" trong dự án).
  Future<Map<String, dynamic>?> getNextPendingBoard(
    int idLot,
    int afterBoardId,
    String? afterBoardCode, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final afterCodeNum = int.tryParse(afterBoardCode ?? '') ?? 0;
    // Lọc aoi_machine: lot có thể bị 2 máy dùng chung (lot_code chỉ là
    // ngày) - không lọc sẽ nhảy nhầm sang board của máy khác khi các board
    // xen kẽ nhau theo (board_code, id_board).
    final machineClause = aoiMachine == null ? '' : 'AND aoi_machine = ?';
    final results = await db.rawQuery(
      '''
      SELECT * FROM tbBoard
      WHERE tbLotid_lot = ?
        AND (status IS NULL OR status != 'completed')
        $machineClause
        AND (
          CAST(board_code AS INTEGER) > ?
          OR (CAST(board_code AS INTEGER) = ? AND id_board > ?)
        )
      ORDER BY CAST(board_code AS INTEGER) ASC, id_board ASC
      LIMIT 1
      ''',
      [
        idLot,
        if (aoiMachine != null) aoiMachine,
        afterCodeNum,
        afterCodeNum,
        afterBoardId,
      ],
    );
    return results.isNotEmpty ? results.first : null;
  }

  // ========== DEFECT OPERATIONS ==========
  Future<int> insertDefect(Map<String, dynamic> defect) async {
    final db = await database;
    return await db.insert(
      'tbDefect',
      defect,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAllDefects() async {
    final db = await database;
    return await db.query('tbDefect', orderBy: 'time DESC');
  }

  Future<List<Map<String, dynamic>>> getDefectsByBoard(int idBoard) async {
    final db = await database;
    return await db.query(
      'tbDefect',
      where: 'tbBoardid_board = ?',
      whereArgs: [idBoard],
      // Order by primary key (insertion order) for deterministic processing
      orderBy: 'id_defect ASC',
    );
  }

  Future<Map<String, dynamic>?> getDefectById(int idDefect) async {
    final db = await database;
    final results = await db.query(
      'tbDefect',
      where: 'id_defect = ?',
      whereArgs: [idDefect],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<List<Map<String, dynamic>>> getDefectsByType(String defectType) async {
    final db = await database;
    return await db.query(
      'tbDefect',
      where: 'type = ?',
      whereArgs: [defectType],
      orderBy: 'time DESC',
    );
  }

  /// Update fields of a defect row by its id_defect.
  /// Returns number of rows affected.
  Future<int> updateDefect(int idDefect, Map<String, dynamic> fields) async {
    Database db = await database;
    try {
      final result = await _updateDefectWithRetry(db, idDefect, fields);
      debugPrint(
        '✅ Updated defect $idDefect successfully ($result rows affected)',
      );
      return result;
    } catch (e) {
      debugPrint('❌ LocalDatabaseService.updateDefect failed: $e');
      final errMsg = e.toString();
      // If failure caused by read-only file system, try to reinitialize DB (will trigger writable fallback)
      if (errMsg.toLowerCase().contains('read-only') ||
          errMsg.toLowerCase().contains('read only')) {
        debugPrint(
          '🔄 Detected read-only DB; attempting to reopen database and retry update',
        );
        try {
          if (_db != null) {
            try {
              await _db!.close();
            } catch (_) {}
            _db = null;
          }
          db =
              await database; // re-open (fallback copy logic in _initDatabase will run)
          final retryResult = await _updateDefectWithRetry(
            db,
            idDefect,
            fields,
          );
          debugPrint(
            '✅ Retry successful: Updated defect $idDefect ($retryResult rows affected)',
          );
          return retryResult; // ✅ Return success, don't rethrow!
        } catch (re) {
          debugPrint('❌ Retry after reopening DB failed: $re');
          rethrow;
        }
      }
      rethrow;
    }
  }

  Future<int> _updateDefectWithRetry(
    Database db,
    int idDefect,
    Map<String, dynamic> fields,
  ) async {
    const retryDelays = [
      Duration(milliseconds: 120),
      Duration(milliseconds: 300),
      Duration(milliseconds: 700),
    ];

    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      try {
        return await db.update(
          'tbDefect',
          fields,
          where: 'id_defect = ?',
          whereArgs: [idDefect],
        );
      } catch (e) {
        final errMsg = e.toString().toLowerCase();
        final isLocked =
            errMsg.contains('database is locked') ||
            errMsg.contains('sqlite_error: 5') ||
            errMsg.contains('database locked');

        if (!isLocked || attempt == retryDelays.length) {
          rethrow;
        }

        debugPrint(
          'Database locked while updating defect $idDefect; retry ${attempt + 1}/${retryDelays.length}',
        );
        await Future.delayed(retryDelays[attempt]);
      }
    }

    throw StateError('Unreachable update retry state');
  }

  // ========== CONFIG OPERATIONS ==========
  Future<int> insertConfig(Map<String, dynamic> config) async {
    final db = await database;
    return await db.insert(
      'tbConfig',
      config,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAllConfigs() async {
    final db = await database;
    return await db.query('tbConfig');
  }

  Future<String?> getConfigValue(String key) async {
    final db = await database;
    final results = await db.query(
      'tbConfig',
      where: 'config_key = ?',
      whereArgs: [key],
    );
    return results.isNotEmpty ? results.first['config_value'] as String? : null;
  }

  Future<int> updateConfig(String key, String value) async {
    final db = await database;
    return await db.update(
      'tbConfig',
      {'config_value': value},
      where: 'config_key = ?',
      whereArgs: [key],
    );
  }

  // ========== STATISTICS OPERATIONS ==========

  /// Đếm số lỗi theo loại, sắp xếp giảm dần.
  ///
  /// [idLot] `null` = toàn bộ DB (mọi lô, mọi model). Có giá trị = chỉ lô đó.
  ///
  /// Gom theo loại lỗi ĐÃ XÁC NHẬN KHI SOI - ưu tiên `human_type` (người vận
  /// hành tự chọn khi phán định NG), fallback `ai_type` (AI đoán) - chứ KHÔNG
  /// theo `type`: `type` là mã SỐ thô của máy AOI (`str(type_code)`, ví dụ
  /// `"2"`) và hệ thống không có bảng ánh xạ mã đó sang tên lỗi, nên gom theo nó
  /// thì bảng thống kê hiện ra "2", "5"... và mọi ô đều rơi vào màu mặc định.
  ///
  /// Ưu tiên `human_type` giữ đúng ý nghĩa vốn có của hàm này ("loại lỗi xác
  /// nhận khi soi") sau khi tách cột: người vận hành sửa loại lỗi AI đoán sai
  /// thì thống kê phải theo họ. Không làm đổi số liệu cũ - mọi dòng có sẵn đều
  /// có `human_type` NULL nên rơi đúng về `ai_type` như trước.
  ///
  /// Lỗi chưa phán định (cả 2 cột NULL/rỗng) gom vào [kUnjudgedDefectKey] chứ
  /// không bị loại, để tổng khớp với số lỗi thật.
  Future<Map<String, int>> getDefectStatistics({int? idLot}) async {
    final db = await database;

    // COALESCE(NULLIF(TRIM(...), ''), ?) gộp cả NULL lẫn chuỗi rỗng/toàn khoảng
    // trắng vào cùng một nhóm "chưa soi".
    const typeExpr =
        "COALESCE(NULLIF(TRIM(d.human_type), ''), "
        "NULLIF(TRIM(d.ai_type), ''), ?) AS defect_type";

    final results = idLot == null
        ? await db.rawQuery(
            '''
            SELECT $typeExpr, COUNT(*) AS count
            FROM tbDefect d
            GROUP BY defect_type
            ORDER BY count DESC
          ''',
            [kUnjudgedDefectKey],
          )
        : await db.rawQuery(
            '''
            SELECT $typeExpr, COUNT(*) AS count
            FROM tbDefect d
            JOIN tbBoard b ON d.tbBoardid_board = b.id_board
            WHERE b.tbLotid_lot = ?
            GROUP BY defect_type
            ORDER BY count DESC
          ''',
            [kUnjudgedDefectKey, idLot],
          );

    final Map<String, int> stats = {};
    for (final row in results) {
      final key = row['defect_type']?.toString() ?? kUnjudgedDefectKey;

      // `count` should be an int, but be defensive in case it's returned as String.
      int count = 0;
      if (row['count'] is int) {
        count = row['count'] as int;
      } else if (row['count'] != null) {
        count = int.tryParse(row['count'].toString()) ?? 0;
      }

      stats[key] = count;
    }
    return stats;
  }

  /// Danh sách lô để lọc cho báo cáo (vd AiAgreementScreen) - KHÔNG giới
  /// hạn "còn việc chưa xử lý" như [getSelectableLotsForModel] (hàm đó phục
  /// vụ vận hành chọn lô để CHẠY, còn đây phục vụ XEM LẠI báo cáo nên cần cả
  /// lô đã xử lý xong). [idModel]/[aoiMachine] null = không lọc theo tiêu
  /// chí đó.
  Future<List<Map<String, dynamic>>> getLotsForReport({
    int? idModel,
    String? aoiMachine,
  }) async {
    final db = await database;
    if (idModel == null && aoiMachine == null) {
      return await getAllLots();
    }
    final where = StringBuffer('1=1');
    final args = <Object?>[];
    if (idModel != null) {
      where.write(' AND l.tbModelid_model = ?');
      args.add(idModel);
    }
    if (aoiMachine != null) {
      where.write(
        ' AND EXISTS (SELECT 1 FROM tbBoard b '
        'WHERE b.tbLotid_lot = l.id_lot AND b.aoi_machine = ?)',
      );
      args.add(aoiMachine);
    }
    return await db.rawQuery('''
      SELECT DISTINCT l.* FROM tbLot l
      WHERE $where
      ORDER BY l.id_lot DESC
      ''', args);
  }

  /// Độ khớp giữa phán định CUỐI của người (`judgement`) và phán định riêng
  /// của AI (`ai_verdict`) - đo AI báo THỪA (AI nói NG, người xác nhận OK)
  /// hay báo THIẾU (AI nói OK, người xác nhận NG) bao nhiêu, phục vụ đánh
  /// giá độ chính xác AI qua thời gian (xem yêu cầu tính năng "tỉ lệ lệch
  /// lỗi giữa người và máy").
  ///
  /// Chỉ tính các dòng đã có ĐỦ CẢ 2 giá trị (đã phán định thủ công VÀ đã
  /// từng chạy qua AI) - lỗi chưa soi, hoặc soi mà không qua bước AI, không
  /// tính vào mẫu so sánh (không có gì để so).
  ///
  /// [idLot] null = mọi lô. [idModel] null = mọi model - lọc rộng hơn
  /// [idLot] (dùng khi chỉ muốn xem theo model, không chốt 1 lô cụ thể);
  /// truyền cả hai thì [idLot] tự nhiên đã hẹp hơn nên không xung đột.
  /// [fromDate]/[toDate] lọc theo cột `time` (thời điểm phán định) - so sánh
  /// chuỗi ISO8601 nên vẫn đúng thứ tự thời gian mà không cần parse.
  /// [aoiMachine] null = mọi máy - lô có thể bị nhiều máy AOI dùng chung
  /// (xem AoiMachineProvider), nên cần lọc theo `b.aoi_machine` để không gộp
  /// lẫn số liệu của máy khác vào báo cáo.
  Future<Map<String, dynamic>> getAiHumanAgreementStats({
    int? idLot,
    int? idModel,
    DateTime? fromDate,
    DateTime? toDate,
    String? aoiMachine,
  }) async {
    final db = await database;
    final where = StringBuffer(
      "d.judgement IS NOT NULL AND TRIM(d.judgement) != '' "
      "AND d.ai_verdict IS NOT NULL AND TRIM(d.ai_verdict) != ''",
    );
    final args = <Object?>[];
    if (idLot != null) {
      where.write(' AND b.tbLotid_lot = ?');
      args.add(idLot);
    }
    if (idModel != null) {
      where.write(' AND l.tbModelid_model = ?');
      args.add(idModel);
    }
    if (aoiMachine != null) {
      where.write(' AND b.aoi_machine = ?');
      args.add(aoiMachine);
    }
    if (fromDate != null) {
      where.write(' AND d.time >= ?');
      args.add(fromDate.toIso8601String());
    }
    if (toDate != null) {
      where.write(' AND d.time <= ?');
      args.add(toDate.toIso8601String());
    }

    final rows = await db.rawQuery('''
      SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN UPPER(d.judgement) = UPPER(d.ai_verdict) THEN 1 ELSE 0 END) AS agree,
        SUM(CASE WHEN UPPER(d.ai_verdict) = 'NG' AND UPPER(d.judgement) = 'OK' THEN 1 ELSE 0 END) AS ai_ng_human_ok,
        SUM(CASE WHEN UPPER(d.ai_verdict) = 'OK' AND UPPER(d.judgement) = 'NG' THEN 1 ELSE 0 END) AS ai_ok_human_ng
      FROM tbDefect d
      JOIN tbBoard b ON b.id_board = d.tbBoardid_board
      JOIN tbLot l ON l.id_lot = b.tbLotid_lot
      WHERE $where
      ''', args);
    final row = rows.isNotEmpty ? rows.first : const {};

    int asInt(Object? v) {
      if (v is int) return v;
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    return {
      'total': asInt(row['total']),
      'agree': asInt(row['agree']),
      'aiNgHumanOk': asInt(row['ai_ng_human_ok']),
      'aiOkHumanNg': asInt(row['ai_ok_human_ng']),
    };
  }

  Future<Map<String, dynamic>> getLotStatistics(int idLot) async {
    final db = await database;

    // Get total boards for this lot
    final totalResult = await db.rawQuery(
      '''
      SELECT COUNT(*) as total FROM tbBoard WHERE tbLotid_lot = ?
    ''',
      [idLot],
    );
    final total = totalResult.first['total'] as int;

    // Get boards with defects (defect_quantity > 0)
    final ngResult = await db.rawQuery(
      '''
      SELECT COUNT(*) as ng FROM tbBoard WHERE tbLotid_lot = ? AND defect_quantity > 0
    ''',
      [idLot],
    );
    final ng = ngResult.first['ng'] as int;

    final ok = total - ng;
    final ngRate = total > 0 ? (ng / total) * 100 : 0.0;

    return {'total': total, 'ok': ok, 'ng': ng, 'ngRate': ngRate};
  }

  Future<List<Map<String, dynamic>>> getAllLotStatistics() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT
        l.id_lot,
        l.lot_code,
        l.board_quantity,
        l.NG_rate,
        l.fakeDef,
        COUNT(b.id_board) as actual_boards,
        SUM(CASE WHEN b.defect_quantity > 0 THEN 1 ELSE 0 END) as ng_boards,
        SUM(CASE WHEN b.defect_quantity = 0 THEN 1 ELSE 0 END) as ok_boards
      FROM tbLot l
      LEFT JOIN tbBoard b ON l.id_lot = b.tbLotid_lot
      GROUP BY l.id_lot
      ORDER BY l.id_lot DESC
    ''');
  }

  // ========== UTILITY OPERATIONS ==========
  Future<void> clearAllTables() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('tbDefect');
      await txn.delete('tbBoard');
      await txn.delete('tbLot');
      await txn.delete('tbModel');
      await txn.delete('tbConfig');
    });
  }

  Future<Map<String, dynamic>> getDatabaseInfo() async {
    final db = await database;

    final modelCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM tbModel'),
        ) ??
        0;
    final lotCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM tbLot'),
        ) ??
        0;
    final boardCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM tbBoard'),
        ) ??
        0;
    final defectCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM tbDefect'),
        ) ??
        0;
    final configCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM tbConfig'),
        ) ??
        0;

    return {
      'models': modelCount,
      'lots': lotCount,
      'boards': boardCount,
      'defects': defectCount,
      'configs': configCount,
    };
  }

  // Close database
  Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  /// Lấy lot "đang chạy" cho 1 model: lot cũ nhất (id_lot ASC) mà vẫn còn
  /// board chưa hoàn tất, hoặc chưa có board nào cả - cùng nguyên tắc với
  /// "board tiếp theo" (xem getFirstBoardByLotId) nhưng áp dụng ở cấp lot.
  /// Nếu MỌI lot của model đã hoàn tất hết, trả về lot MỚI NHẤT (id_lot DESC)
  /// để màn hình vẫn hiện được thông tin gì đó, thay vì "Chưa có" dù model
  /// đã có dữ liệu.
  ///
  /// Trước đây (`getFirstLotByModelId`, đã xoá) chỉ lấy lot cũ nhất vô điều
  /// kiện - đúng khi 1 model chỉ có duy nhất 1 lot (quy ước cũ của
  /// AOI_Ingest: tái sử dụng mãi 1 lot rỗng). Từ khi AOI_Ingest tạo 1 lot
  /// MỚI cho mỗi lot_code AOI ghi ra (xem AOI_Ingest/aoi_ingest_service.py::
  /// get_or_create_lot), 1 model có thể tích luỹ nhiều lot theo thời gian,
  /// và "cũ nhất" sẽ mãi đứng ở lot đầu tiên chứ không theo lot đang chạy
  /// thật - đây là hàm thay thế đúng ngữ nghĩa hơn.
  // Lot "chưa xong": chưa có board nào (của đúng máy [aoiMachine] nếu có
  // lọc), hoặc còn ít nhất 1 board (của máy đó) chưa 'completed'. Dùng chung
  // bởi getCurrentLotForModel (tự động chọn 1 lot) và getSelectableLotsForModel
  // (liệt kê cho vận hành viên tự chọn) - cùng một định nghĩa "còn việc để
  // làm" ở cấp lot.
  //
  // 1 dòng tbLot có thể bị NHIỀU máy AOI dùng chung (lot_code chỉ là ngày,
  // xem AoiMachineProvider) - "chưa xong" phải xét THEO MÁY: lot có board của
  // máy khác đã completed hết không có nghĩa lot đó "xong" với máy hiện tại
  // nếu máy hiện tại chưa từng ghi board nào vào đó, hoặc còn board pending
  // riêng của máy mình.
  //
  // Trả về (where, args) thay vì String cố định: cần nhét thêm [aoiMachine]
  // vào đúng 2 chỗ `?` bên trong (khi có lọc máy) - dùng record để args luôn
  // đi kèm đúng vị trí với SQL, tránh lỗi đếm nhầm thứ tự tham số.
  static ({String where, List<Object?> args}) _unfinishedLotWhere(
    String? aoiMachine,
  ) {
    if (aoiMachine == null) {
      return (
        where: '''
          (
            NOT EXISTS (SELECT 1 FROM tbBoard b WHERE b.tbLotid_lot = l.id_lot)
            OR EXISTS (
              SELECT 1 FROM tbBoard b
              WHERE b.tbLotid_lot = l.id_lot
                AND (b.status IS NULL OR b.status != 'completed')
            )
          )
        ''',
        args: const <Object?>[],
      );
    }
    return (
      where: '''
        (
          NOT EXISTS (
            SELECT 1 FROM tbBoard b
            WHERE b.tbLotid_lot = l.id_lot AND b.aoi_machine = ?
          )
          OR EXISTS (
            SELECT 1 FROM tbBoard b
            WHERE b.tbLotid_lot = l.id_lot AND b.aoi_machine = ?
              AND (b.status IS NULL OR b.status != 'completed')
          )
        )
      ''',
      args: [aoiMachine, aoiMachine],
    );
  }

  // Board (alias `b` trong câu SELECT gọi tới) CHƯA thuộc bất kỳ đợt
  // (tbBoardBatch) nào của lot đó. Dùng chung bởi getEligibleBoardsForBatch
  // (liệt kê board khả dụng cho màn chọn đợt) và getSelectableLotsForModel
  // (đếm "còn N board chưa vào đợt" để nhắc vận hành viên) - tính cả các
  // khoảng trống GIỮA các đợt, không chỉ phần "trước đợt đầu tiên", vì vận
  // hành viên có thể quay lại lấp 1 khoảng trống sau khi đã chạy đợt sau đó.
  //
  // CHỈ xét đợt của CÙNG MÁY với board đang lọc (so `bb.aoi_machine` với
  // `b.aoi_machine`, không cần tham số) - cùng lý do đã ghi ở
  // rangeOverlapsExistingBatch: id_board là AUTOINCREMENT dùng chung cho mọi
  // máy, nên 1 đợt của máy khác hoàn toàn có thể "phủ" lên id_board của board
  // thuộc máy này mà thực tế không liên quan gì tới nhau. Không lọc máy ở đây
  // sẽ giấu mất board hợp lệ khỏi màn chọn đợt (operator hết đợt mà không
  // chọn được board nào để chạy lượt tiếp theo) - lot dùng chung giữa 2 máy
  // đã có thật trong DB.
  static const String _boardNotInAnyBatchWhere = '''
    NOT EXISTS (
      SELECT 1 FROM tbBoardBatch bb
      WHERE bb.tbLotid_lot = b.tbLotid_lot
        AND IFNULL(bb.aoi_machine, '') = IFNULL(b.aoi_machine, '')
        AND bb.start_id_board <= b.id_board
        AND bb.end_id_board >= b.id_board
    )
  ''';

  Future<Map<String, dynamic>?> getCurrentLotForModel(
    String idModel, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final unfinishedWhere = _unfinishedLotWhere(aoiMachine);
    final unfinished = await db.rawQuery(
      '''
      SELECT l.* FROM tbLot l
      WHERE l.tbModelid_model = ?
        AND ${unfinishedWhere.where}
      ORDER BY l.id_lot ASC
      LIMIT 1
      ''',
      [idModel, ...unfinishedWhere.args],
    );
    if (unfinished.isNotEmpty) return unfinished.first;

    final all = await db.query(
      'tbLot',
      where: 'tbModelid_model = ?',
      whereArgs: [idModel],
      orderBy: 'id_lot DESC',
      limit: 1,
    );
    return all.isNotEmpty ? all.first : null;
  }

  /// Liệt kê mọi lot CHƯA xong của 1 model (xem _unfinishedLotWhere), để vận
  /// hành viên tự chọn lot muốn xử lý sau khi chọn model - thay vì app tự
  /// đoán như getCurrentLotForModel. Lot đã xử lý hết board (mọi board
  /// 'completed') sẽ KHÔNG xuất hiện trong danh sách này.
  ///
  /// Kèm `actual_boards`/`pending_boards` (đếm thật từ tbBoard) thay vì
  /// dùng `tbLot.board_quantity` - cột đó AOI_Ingest không hề ghi vào nên
  /// luôn NULL, không phản ánh số bo thật đã nhận cho lot.
  ///
  /// `actual_boards`/`pending_boards` đếm DÒNG (mỗi dòng = 1 file A.vrs/B.vrs
  /// AOI ghi) - KHÔNG chắc luôn đúng 2 dòng/board (vận hành viên cho biết có
  /// thể 1 mặt không tạo dòng nếu mặt đó không có lỗi), nên KHÔNG suy ra số
  /// board vật lý bằng cách chia đôi số dòng - `total_boards` mới là số board
  /// vật lý thật (đếm DISTINCT board_code, đúng dù 1 board có 1 hay 2 dòng),
  /// dùng cột này cho "Tổng số bo".
  Future<List<Map<String, dynamic>>> getSelectableLotsForModel(
    String idModel, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final unfinishedWhere = _unfinishedLotWhere(aoiMachine);
    // Lọc máy ngay trong ON của LEFT JOIN (không phải WHERE): board của máy
    // khác phải bị loại TRƯỚC KHI tính COUNT/SUM, chứ không phải sau - lọc ở
    // WHERE sẽ biến LEFT JOIN thành INNER JOIN trên cột đó và loại nhầm cả
    // những lot không có board nào của máy này.
    final joinMachineClause = aoiMachine == null ? '' : 'AND b.aoi_machine = ?';
    final args = <Object?>[
      if (aoiMachine != null) aoiMachine,
      idModel,
      ...unfinishedWhere.args,
    ];
    return await db.rawQuery('''
      SELECT l.*,
        COUNT(b.id_board) as actual_boards,
        COUNT(DISTINCT b.board_code) as total_boards,
        SUM(CASE WHEN b.status IS NULL OR b.status != 'completed' THEN 1 ELSE 0 END) as pending_boards,
        COUNT(DISTINCT CASE
          WHEN (b.status IS NULL OR b.status != 'completed')
            AND $_boardNotInAnyBatchWhere
          THEN b.board_code END) as uncovered_boards
      FROM tbLot l
      LEFT JOIN tbBoard b ON b.tbLotid_lot = l.id_lot $joinMachineClause
      WHERE l.tbModelid_model = ?
        AND ${unfinishedWhere.where}
      GROUP BY l.id_lot
      ORDER BY l.id_lot ASC
      ''', args);
  }

  /// Lấy board "bắt đầu/tiếp tục" cho 1 lot: board có board_code NHỎ NHẤT
  /// (không phải id_board nhỏ nhất - xem ghi chú dưới) nhưng CHƯA hoàn tất
  /// (status khác 'completed', hoặc board cũ chưa có status). Dùng khi chọn
  /// model (setCurrentModel) và khi app khởi động lại
  /// (_resolveFirstLotAndBoardForModel) - nếu chỉ lấy id_board nhỏ nhất mà
  /// không lọc status, app sẽ quay lại đúng board đã xử lý xong mỗi lần chọn
  /// lại model / mở lại app, thay vì board tiếp theo đang chờ.
  ///
  /// Sắp theo board_code (ép kiểu số), KHÔNG theo id_board: id_board chỉ là
  /// thứ tự AOI_Ingest ghi vào DB, tức thứ tự AOI thực sự xử lý xong board đó
  /// - thứ tự này KHÔNG đảm bảo trùng với board_code tăng dần (bug thật gặp
  /// 2026-09-15: lot có board_code='10521' được AOI ghi vào DB TRƯỚC
  /// board_code='8555' dù 8555 nhỏ hơn, nên id_board ASC chọn nhầm 10521 làm
  /// board đầu). `id_board ASC` chỉ còn dùng làm tie-break cho các dòng cùng
  /// board_code (board_code không unique - 1 board có nhiều dòng layer/mặt).
  Future<Map<String, dynamic>?> getFirstBoardByLotId(
    String idLot, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final where = StringBuffer(
      'tbLotid_lot = ? AND (status IS NULL OR status != ?)',
    );
    final whereArgs = <Object?>[idLot, 'completed'];
    if (aoiMachine != null) {
      where.write(' AND aoi_machine = ?');
      whereArgs.add(aoiMachine);
    }
    final boards = await db.query(
      'tbBoard',
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'CAST(board_code AS INTEGER) ASC, id_board ASC',
    );
    return boards.isNotEmpty ? boards.first : null;
  }

  // ========== BOARD BATCH ("đợt") OPERATIONS ==========
  //
  // 1 lot có thể có nhiều board hơn máy VRS thật tải được mỗi lần (~100 board
  // hoặc ít hơn). "Đợt" = 1 khoảng board (theo board_code) vận hành viên chọn
  // mỗi lần nạp máy, lưu lại để Auto VRS chỉ chạy trong đúng khoảng đó và nhớ
  // được các đợt đã chạy qua nhiều ca/nhiều lần mở app.

  /// Đợt CÒN VIỆC của lot (nếu có). KHÔNG tin cột `status` tuyệt đối - suy ra
  /// "còn việc" bằng cách kiểm tra thật còn board pending trong khoảng
  /// [start_id_board, end_id_board] của đợt đó, để tự "chữa lành" nếu có lần
  /// nào đó markBatchCompleted không kịp chạy (vd app tắt giữa lúc board cuối
  /// đợt vừa xong) - cột status/completed_at chỉ còn ý nghĩa audit, không ai
  /// dựa vào đó để QUYẾT ĐỊNH hành vi.
  Future<Map<String, dynamic>?> getActiveBatchForLot(
    int idLot, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final machineClause = aoiMachine == null ? '' : 'AND bb.aoi_machine = ?';
    // Board bên trong EXISTS phải lọc máy ĐÚNG như getFirstPendingBoardInBatch
    // (hàm thực sự đi lấy board của đợt): id_board AUTOINCREMENT dùng chung
    // mọi máy nên board máy khác có thể chen vào giữa biên đợt. Lệch nhau ở
    // điểm này = đợt vẫn bị coi là "còn việc" nhờ board của máy khác, trong
    // khi getFirstPendingBoardInBatch không trả về gì -> _applyLot giữ đợt
    // rỗng đó làm đợt active và KHÔNG bật batchFinished, màn hình không hiện
    // nút "Chọn đợt mới" nào cả (operator kẹt, không chạy được lượt tiếp).
    final boardMachineClause = aoiMachine == null
        ? ''
        : 'AND b.aoi_machine = ?';
    final rows = await db.rawQuery(
      '''
      SELECT bb.* FROM tbBoardBatch bb
      WHERE bb.tbLotid_lot = ?
        $machineClause
        AND EXISTS (
          SELECT 1 FROM tbBoard b
          WHERE b.tbLotid_lot = bb.tbLotid_lot
            AND b.id_board BETWEEN bb.start_id_board AND bb.end_id_board
            AND (b.status IS NULL OR b.status != 'completed')
            $boardMachineClause
        )
      ORDER BY bb.id_batch DESC
      LIMIT 1
      ''',
      [
        idLot,
        if (aoiMachine != null) aoiMachine,
        if (aoiMachine != null) aoiMachine,
      ],
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  /// Đợt mới nhất của lot (theo đúng máy [aoiMachine] nếu có lọc), KHÔNG lọc
  /// còn việc hay không - chỉ dùng để tự sửa (self-heal) cột status/
  /// completed_at khi phát hiện đợt đó đã thực sự hết việc (xem
  /// getActiveBatchForLot) mà chưa được đánh dấu completed.
  ///
  /// [aoiMachine] BẮT BUỘC phải truyền khi đã biết máy đang chọn: lot có thể
  /// bị nhiều máy dùng chung, nếu không lọc, "đợt mới nhất của lot" có thể là
  /// đợt của MÁY KHÁC - self-heal (markBatchCompleted) sẽ đánh dấu completed
  /// nhầm 1 đợt của máy khác đang còn chạy dở.
  Future<Map<String, dynamic>?> getMostRecentBatchForLot(
    int idLot, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final where = StringBuffer('tbLotid_lot = ?');
    final whereArgs = <Object?>[idLot];
    if (aoiMachine != null) {
      where.write(' AND aoi_machine = ?');
      whereArgs.add(aoiMachine);
    }
    final rows = await db.query(
      'tbBoardBatch',
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'id_batch DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> markBatchCompleted(int idBatch) async {
    final db = await database;
    return await db.update(
      'tbBoardBatch',
      {'status': 'completed', 'completed_at': DateTime.now().toIso8601String()},
      where: 'id_batch = ?',
      whereArgs: [idBatch],
    );
  }

  Future<int> createBoardBatch({
    required int idLot,
    required String startBoardCode,
    required String endBoardCode,
    required int startIdBoard,
    required int endIdBoard,
    String? aoiMachine,
  }) async {
    final db = await database;
    return await db.insert('tbBoardBatch', {
      'tbLotid_lot': idLot,
      'start_board_code': startBoardCode,
      'end_board_code': endBoardCode,
      'start_id_board': startIdBoard,
      'end_id_board': endIdBoard,
      'status': 'in_progress',
      'created_at': DateTime.now().toIso8601String(),
      'aoi_machine': aoiMachine,
    });
  }

  /// Lot đã TỪNG có board nào chưa (bất kể trạng thái) - dùng để phân biệt
  /// "lot đã xử lý xong hoàn toàn" (từng có board, giờ hết pending) với "lot
  /// còn chưa có board nào" (mới, AOI chưa ghi gì) - 2 trường hợp cần thông
  /// báo khác nhau, KHÔNG được gộp chung thành "lotFinished".
  Future<bool> lotHasAnyBoard(int idLot) async {
    final db = await database;
    final rows = await db.query(
      'tbBoard',
      where: 'tbLotid_lot = ?',
      whereArgs: [idLot],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Bản có CẢ 2 biên của getFirstBoardByLotId - dùng khi 1 đợt đang active,
  /// để KHÔNG lùi về board pending trước điểm bắt đầu đợt (vd 1 khoảng trống
  /// vận hành viên chủ ý bỏ qua để chạy trước) lẫn KHÔNG vượt quá điểm kết
  /// thúc đợt.
  Future<Map<String, dynamic>?> getFirstPendingBoardInBatch(
    int idLot,
    int startIdBoard,
    int endIdBoard, {
    String? aoiMachine,
  }) async {
    final db = await database;
    // Biên đợt (start/endIdBoard) vẫn tính theo id_board như cũ - chỉ đổi
    // THỨ TỰ CHỌN bên trong biên đó sang board_code tăng dần, cùng lý do với
    // getFirstBoardByLotId. id_board ASC vẫn là tie-break cho các dòng cùng
    // board_code.
    //
    // Lọc aoi_machine: id_board là AUTOINCREMENT dùng chung cho MỌI máy AOI
    // ghi vào 1 file autovrs.db, nên khoảng [startIdBoard, endIdBoard] của 1
    // đợt (dù đã tạo bằng board của đúng máy này) vẫn có thể "dính" board của
    // máy khác chen giữa theo id_board - phải lọc lại ở đây để không lấy
    // nhầm.
    final where = StringBuffer(
      'tbLotid_lot = ? AND id_board BETWEEN ? AND ? '
      'AND (status IS NULL OR status != ?)',
    );
    final whereArgs = <Object?>[idLot, startIdBoard, endIdBoard, 'completed'];
    if (aoiMachine != null) {
      where.write(' AND aoi_machine = ?');
      whereArgs.add(aoiMachine);
    }
    final boards = await db.query(
      'tbBoard',
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'CAST(board_code AS INTEGER) ASC, id_board ASC',
      limit: 1,
    );
    return boards.isNotEmpty ? boards.first : null;
  }

  /// Bản có biên trên (endIdBoard) của getNextPendingBoard - tìm board
  /// pending tiếp theo (id_board > afterBoardId) nhưng KHÔNG vượt quá biên
  /// đợt. Dùng trong completeCurrentBoardAndCheckNext để không nhầm "hết
  /// board TRONG đợt" (phải chọn đợt mới) với "hết board TRONG CẢ LOT" (thật
  /// sự xong) khi lot còn 1 khoảng trống TRƯỚC đợt hiện tại - bug đã gặp:
  /// đợt sau (id lớn) chạy trước, hoàn tất board cuối cùng của cả lot xét
  /// theo id_board, code cũ kết luận "lotFinished" dù khoảng trống trước đợt
  /// vẫn còn nguyên board pending.
  /// Bản có biên trên (endIdBoard) của [getNextPendingBoard] - cùng cách sắp
  /// theo cặp (board_code, id_board) tăng dần, chỉ thêm điều kiện không vượt
  /// quá biên đợt. Biên `endIdBoard` VẪN tính theo id_board như cũ (do đợt
  /// lưu biên bằng id_board - xem tbBoardBatch) - CHƯA đổi sang board_code
  /// (rủi ro còn lại, xem ghi chú khi báo cáo cho user).
  Future<Map<String, dynamic>?> getNextPendingBoardInBatch(
    int idLot,
    int afterBoardId,
    String? afterBoardCode,
    int endIdBoard, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final afterCodeNum = int.tryParse(afterBoardCode ?? '') ?? 0;
    final machineClause = aoiMachine == null ? '' : 'AND aoi_machine = ?';
    final results = await db.rawQuery(
      '''
      SELECT * FROM tbBoard
      WHERE tbLotid_lot = ?
        AND id_board <= ?
        AND (status IS NULL OR status != 'completed')
        $machineClause
        AND (
          CAST(board_code AS INTEGER) > ?
          OR (CAST(board_code AS INTEGER) = ? AND id_board > ?)
        )
      ORDER BY CAST(board_code AS INTEGER) ASC, id_board ASC
      LIMIT 1
      ''',
      [
        idLot,
        endIdBoard,
        if (aoiMachine != null) aoiMachine,
        afterCodeNum,
        afterCodeNum,
        afterBoardId,
      ],
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// Khoảng [startIdBoard, endIdBoard] có chồng lên đợt NÀO khác của lot này
  /// không (chuẩn kiểm tra overlap 2 khoảng: A<=D AND C<=B). Dùng để CHẶN
  /// tạo đợt chồng chéo - bug đã gặp: getEligibleBoardsForBatch trả về HỢP
  /// của các khoảng trống rời rạc (vd 51-59 và 101-150 nếu 60-100 đã thuộc 1
  /// đợt khác), màn chọn đợt tự điền sẵn "đầu = board đầu tiên, cuối = board
  /// cuối cùng" của DANH SÁCH ĐÃ GỘP đó (51 và 150) - nếu chỉ kiểm tra riêng
  /// 2 đầu mà không kiểm tra cả khoảng ở giữa, operator bấm Xác nhận theo
  /// đúng mặc định app tự điền sẽ tạo ra đợt 51-150 chồng lên đợt 60-100.
  ///
  /// [aoiMachine]: chỉ xét chồng lấn với đợt CỦA CÙNG MÁY - id_board dùng
  /// chung AUTOINCREMENT cho mọi máy nên 2 đợt của 2 máy khác nhau có thể
  /// "chồng" về mặt số id_board mà không hề chồng về board thật (khác máy).
  /// Không lọc máy ở đây sẽ báo lỗi giả (chặn nhầm 1 khoảng hợp lệ).
  Future<bool> rangeOverlapsExistingBatch(
    int idLot,
    int startIdBoard,
    int endIdBoard, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final machineClause = aoiMachine == null ? '' : 'AND bb.aoi_machine = ?';
    final rows = await db.rawQuery(
      '''
      SELECT 1 FROM tbBoardBatch bb
      WHERE bb.tbLotid_lot = ?
        $machineClause
        AND bb.start_id_board <= ? AND bb.end_id_board >= ?
      LIMIT 1
      ''',
      [idLot, if (aoiMachine != null) aoiMachine, endIdBoard, startIdBoard],
    );
    return rows.isNotEmpty;
  }

  /// board_code KHÔNG unique trong 1 lot - 1 board vật lý có nhiều dòng
  /// tbBoard, mỗi dòng 1 layer/mặt (l1..l8), cùng chung board_code (xem
  /// comment ở vrs_provider.dart). Trả về khoảng id_board bao trọn MỌI dòng
  /// mang mã này, để dùng làm biên đợt bao hết mọi layer/mặt của board đó -
  /// nếu chỉ lấy 1 dòng đơn lẻ sẽ cắt cụt các layer sau của board cuối đợt.
  ///
  /// [aoiMachine]: board_code KHÔNG chỉ không-unique trong 1 lot (nhiều
  /// layer) mà còn có thể TRÙNG giữa 2 máy khác nhau dùng chung lot (mỗi máy
  /// tự đánh số board riêng, hoàn toàn có thể cùng ra "1", "2"...) - dùng khi
  /// vận hành viên GÕ TAY mã board vào ô đầu/cuối đợt (xem
  /// select_board_batch_screen.dart::_resolveOrExplain). Không lọc máy ở đây
  /// có thể trả về board_code của máy khác, khiến đợt tạo ra bao trùm nhầm
  /// board không thuộc máy đang chọn.
  Future<Map<String, dynamic>?> resolveBoardCodeRange(
    int idLot,
    String boardCode, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final where = StringBuffer('tbLotid_lot = ? AND board_code = ?');
    final whereArgs = <Object?>[idLot, boardCode];
    if (aoiMachine != null) {
      where.write(' AND aoi_machine = ?');
      whereArgs.add(aoiMachine);
    }
    final result = await db.rawQuery('''
      SELECT MIN(id_board) AS min_id_board, MAX(id_board) AS max_id_board,
             COUNT(*) AS row_count
      FROM tbBoard WHERE $where
      ''', whereArgs);
    final row = result.first;
    return (row['row_count'] as int) > 0 ? row : null;
  }

  /// Board pending của lot CHƯA thuộc đợt nào, group theo board_code (1 dòng
  /// / board vật lý, kèm khoảng id_board + số layer) - dùng làm danh sách +
  /// mặc định (dòng đầu = start, dòng cuối = end) cho màn chọn đợt.
  ///
  /// Sắp theo board_code (ép kiểu số) tăng dần, KHÔNG theo id_board - cùng lý
  /// do với getFirstBoardByLotId/getNextPendingBoard: id_board là thứ tự
  /// AOI_Ingest ghi vào DB, không đảm bảo trùng board_code tăng dần. Danh
  /// sách + mặc định đầu/cuối của màn chọn đợt phải theo board_code để
  /// operator chọn đúng khoảng liền mạch theo số board thật.
  ///
  /// [aoiMachine]: board_code có thể TRÙNG giữa 2 máy dùng chung lot (mỗi máy
  /// tự đánh số riêng) - không lọc sẽ trộn board của máy khác vào danh sách
  /// chọn đợt, và GROUP BY board_code có thể gộp nhầm board của 2 máy khác
  /// nhau làm 1 dòng.
  Future<List<Map<String, dynamic>>> getEligibleBoardsForBatch(
    int idLot, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final machineClause = aoiMachine == null ? '' : 'AND b.aoi_machine = ?';
    return await db.rawQuery(
      '''
      SELECT b.board_code,
        MIN(b.id_board) AS min_id_board,
        MAX(b.id_board) AS max_id_board,
        COUNT(*) AS layer_count
      FROM tbBoard b
      WHERE b.tbLotid_lot = ?
        AND b.board_code IS NOT NULL
        AND (b.status IS NULL OR b.status != 'completed')
        $machineClause
        AND $_boardNotInAnyBatchWhere
      GROUP BY b.board_code
      ORDER BY CAST(b.board_code AS INTEGER) ASC
      ''',
      [idLot, if (aoiMachine != null) aoiMachine],
    );
  }

  // ========== BOARD MANAGEMENT (xoá từng board) ==========
  //
  // Cho phép operator xoá 1 board sai/thừa (vd AOI ghi nhầm, board test) khỏi
  // 1 lot, TRƯỚC khi board đó được xử lý - xem ManageBoardsScreen.

  /// Board CHƯA hoàn tất (status khác 'completed') của 1 lot, group theo
  /// board_code, kèm cờ `in_batch` (board này có đang nằm trong khoảng
  /// id_board của 1 đợt nào không - xem tbBoardBatch). Khác
  /// [getEligibleBoardsForBatch]: hàm đó CHỈ trả board chưa vào đợt nào (để
  /// chọn đợt mới); hàm này trả TẤT CẢ board pending kể cả đã có đợt, để
  /// operator nhìn thấy toàn cảnh trước khi xoá (và không xoá nhầm board đang
  /// trong đợt - UI chặn dựa vào `in_batch`).
  ///
  /// Sắp theo board_code (ép kiểu số) tăng dần, cùng lý do với
  /// getFirstBoardByLotId/getEligibleBoardsForBatch.
  ///
  /// [aoiMachine]: cùng lý do với getEligibleBoardsForBatch - board_code có
  /// thể trùng giữa 2 máy dùng chung lot, không lọc sẽ hiện lẫn (và cho phép
  /// xoá nhầm) board của máy khác.
  Future<List<Map<String, dynamic>>> getPendingBoardsForLotManagement(
    int idLot, {
    String? aoiMachine,
  }) async {
    final db = await database;
    final machineClause = aoiMachine == null ? '' : 'AND b.aoi_machine = ?';
    return await db.rawQuery(
      '''
      SELECT b.board_code,
        MIN(b.id_board) AS min_id_board,
        MAX(b.id_board) AS max_id_board,
        COUNT(*) AS layer_count,
        EXISTS (
          SELECT 1 FROM tbBoard b2
          JOIN tbBoardBatch bb ON bb.tbLotid_lot = b2.tbLotid_lot
            AND bb.start_id_board <= b2.id_board
            AND bb.end_id_board >= b2.id_board
          WHERE b2.tbLotid_lot = b.tbLotid_lot AND b2.board_code = b.board_code
        ) AS in_batch
      FROM tbBoard b
      WHERE b.tbLotid_lot = ?
        AND b.board_code IS NOT NULL
        AND (b.status IS NULL OR b.status != 'completed')
        $machineClause
      GROUP BY b.board_code
      ORDER BY CAST(b.board_code AS INTEGER) ASC
      ''',
      [idLot, if (aoiMachine != null) aoiMachine],
    );
  }

  /// Xoá 1 board (MỌI dòng layer/mặt cùng board_code) khỏi 1 lot. CHỈ cho
  /// phép khi:
  /// - board đang pending (chưa có dòng nào status='completed' - tránh mất
  ///   lịch sử đã phán định thật), VÀ
  /// - board KHÔNG nằm trong khoảng id_board của bất kỳ đợt nào (tránh phá vỡ
  ///   1 đợt đang chạy - xem tbBoardBatch).
  ///
  /// Ném [StateError] với thông báo cụ thể nếu vi phạm 1 trong 2 điều kiện
  /// trên (kiểm tra lại NGAY TRONG transaction, không tin kết quả đã tải ở
  /// màn hình trước đó, để tránh race nếu có thay đổi xen giữa lúc tải danh
  /// sách và lúc bấm xoá) hoặc không tìm thấy board. Xoá cả tbDefect liên
  /// quan trước (không có FK cascade - PRAGMA foreign_keys chưa bật ở DB
  /// này), cùng 1 transaction với xoá tbBoard - xem deleteLot() cho pattern
  /// tương tự.
  ///
  /// [aoiMachine]: board_code có thể TRÙNG giữa 2 máy dùng chung lot - BẮT
  /// BUỘC truyền khi đã biết máy đang chọn, nếu không thao tác xoá có thể
  /// nhắm nhầm board của máy khác (cùng board_code, khác aoi_machine).
  Future<void> deletePendingBoard(
    int idLot,
    String boardCode, {
    String? aoiMachine,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final where = StringBuffer('tbLotid_lot = ? AND board_code = ?');
      final whereArgs = <Object?>[idLot, boardCode];
      if (aoiMachine != null) {
        where.write(' AND aoi_machine = ?');
        whereArgs.add(aoiMachine);
      }

      final rows = await txn.query(
        'tbBoard',
        where: where.toString(),
        whereArgs: whereArgs,
      );
      if (rows.isEmpty) {
        throw StateError('Không tìm thấy board "$boardCode" trong lô này.');
      }
      if (rows.any((r) => r['status']?.toString() == 'completed')) {
        throw StateError(
          'Board "$boardCode" đã có phán định (hoàn tất) - không thể xoá.',
        );
      }

      final inBatchMachineClause = aoiMachine == null
          ? ''
          : 'AND b.aoi_machine = ?';
      final inBatch = await txn.rawQuery(
        '''
        SELECT 1 FROM tbBoardBatch bb
        WHERE bb.tbLotid_lot = ?
          AND EXISTS (
            SELECT 1 FROM tbBoard b
            WHERE b.tbLotid_lot = bb.tbLotid_lot AND b.board_code = ?
              $inBatchMachineClause
              AND b.id_board BETWEEN bb.start_id_board AND bb.end_id_board
          )
        LIMIT 1
        ''',
        [idLot, boardCode, if (aoiMachine != null) aoiMachine],
      );
      if (inBatch.isNotEmpty) {
        throw StateError(
          'Board "$boardCode" đang thuộc 1 đợt - không thể xoá.',
        );
      }

      await txn.delete(
        'tbDefect',
        where: 'tbBoardid_board IN (SELECT id_board FROM tbBoard WHERE $where)',
        whereArgs: whereArgs,
      );
      await txn.delete(
        'tbBoard',
        where: where.toString(),
        whereArgs: whereArgs,
      );
    });
  }
}
