"""
Sinh du lieu test (models/lots/boards/defects) cho autovrs.db de test thuat toan AI.

Cach dung co ban (mac dinh tro thang vao file that ma app doc):
    python generate_test_data.py

Tuy chinh so luong:
    python generate_test_data.py --models 5 --lots-per-model 2 --boards-per-lot 20 --defects-per-board 4

Chi ghi vao file khac (khong dung file that):
    python generate_test_data.py --db "D:\\path\\to\\test.db"

Xoa sach du lieu cu truoc khi sinh moi (can xac nhan):
    python generate_test_data.py --reset

Script CHI dung thu vien chuan cua Python (sqlite3, random, argparse...),
khong can cai them package nao. Chay duoc truc tiep bang `python generate_test_data.py`.
"""

import argparse
import os
import random
import sqlite3
from datetime import datetime, timedelta

DEFAULT_DB_PATH = os.path.join(
    os.path.expanduser("~"), "Documents", "AutoVRS", "autovrs.db"
)

DEFECT_TYPES = [
    "Ho mach",
    "Xuoc mach",
    "Thieu linh kien",
    "Nhiem ban",
    "Han thieu",
    "Han thua",
    "Nhieu anh",
    "Lech linh kien",
    "Bong roc",
    "Vet nut",
]

JUDGEMENTS = ["", "OK", "NG"]  # "" = chua kiem tra, giong du lieu that truoc khi AI chay


def create_tables(conn: sqlite3.Connection) -> None:
    """Tao bang neu chua co, dung dung schema hien tai cua app (kem plc_coor)."""
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS tbModel (
            id_model INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            line_size REAL,
            space_size REAL,
            url_gerber TEXT
        );

        CREATE TABLE IF NOT EXISTS tbLot (
            id_lot INTEGER PRIMARY KEY AUTOINCREMENT,
            NG_rate REAL,
            fakeDef REAL,
            board_quantity INTEGER,
            tbModelid_model INTEGER,
            FOREIGN KEY (tbModelid_model) REFERENCES tbModel(id_model)
        );

        CREATE TABLE IF NOT EXISTS tbBoard (
            id_board INTEGER PRIMARY KEY AUTOINCREMENT,
            defect_quantity INTEGER,
            erro_quantity INTEGER,
            tbLotid_lot INTEGER,
            FOREIGN KEY (tbLotid_lot) REFERENCES tbLot(id_lot)
        );

        CREATE TABLE IF NOT EXISTS tbDefect (
            id_defect INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT,
            judgement TEXT,
            height REAL,
            width REAL,
            time TEXT,
            coordinates TEXT,
            url_image TEXT,
            tbBoardid_board INTEGER,
            plc_coor TEXT,
            FOREIGN KEY (tbBoardid_board) REFERENCES tbBoard(id_board)
        );

        CREATE TABLE IF NOT EXISTS tbConfig (
            config_key TEXT PRIMARY KEY,
            config_value TEXT
        );
        """
    )

    # Neu dang mo file cu (truoc khi co plc_coor), tu them cot con thieu.
    cols = [row[1] for row in conn.execute("PRAGMA table_info(tbDefect)")]
    if "plc_coor" not in cols:
        conn.execute("ALTER TABLE tbDefect ADD COLUMN plc_coor TEXT")


def reset_data(conn: sqlite3.Connection) -> None:
    for table in ("tbDefect", "tbBoard", "tbLot", "tbModel"):
        conn.execute(f"DELETE FROM {table}")
        conn.execute("DELETE FROM sqlite_sequence WHERE name = ?", (table,))


def ensure_default_config(conn: sqlite3.Connection) -> None:
    defaults = {
        "system_mode": "auto",
        "magnification": "140",
        "light_level": "50",
        "dome_light": "50",
        "ring_light": "30",
        "back_light": "70",
        "side_light": "40",
        "system_status": "OK",
    }
    for key, value in defaults.items():
        conn.execute(
            "INSERT OR IGNORE INTO tbConfig (config_key, config_value) VALUES (?, ?)",
            (key, value),
        )


def random_plc_coor(x_max: float, y_max: float) -> str:
    x = round(random.uniform(0, x_max), 1)
    y = round(random.uniform(0, y_max), 1)
    return f"{x};{y}"


def random_time(days_back: int = 14) -> str:
    delta = timedelta(
        days=random.randint(0, days_back),
        hours=random.randint(0, 23),
        minutes=random.randint(0, 59),
        seconds=random.randint(0, 59),
    )
    return (datetime.now() - delta).strftime("%Y-%m-%d %H:%M:%S")


def generate(
    conn: sqlite3.Connection,
    n_models: int,
    lots_per_model: int,
    boards_per_lot: int,
    defects_per_board_max: int,
    empty_board_ratio: float,
    plc_x_max: float,
    plc_y_max: float,
) -> None:
    cur = conn.cursor()

    cur.execute("SELECT COALESCE(MAX(id_model), 0) FROM tbModel")
    model_start = cur.fetchone()[0] + 1

    for m_idx in range(n_models):
        model_no = model_start + m_idx
        cur.execute(
            "INSERT INTO tbModel (name, line_size, space_size, url_gerber) VALUES (?,?,?,?)",
            (
                f"TEST-MODEL-{model_no:03d}",
                round(random.uniform(0.08, 0.2), 3),
                round(random.uniform(0.1, 0.25), 3),
                f"/models/TEST-MODEL-{model_no:03d}.gerber",
            ),
        )
        model_id = cur.lastrowid

        for _ in range(lots_per_model):
            cur.execute(
                "INSERT INTO tbLot (NG_rate, fakeDef, board_quantity, tbModelid_model) VALUES (?,?,?,?)",
                (
                    round(random.uniform(0.01, 0.2), 3),
                    round(random.uniform(0.0, 0.05), 3),
                    random.randint(50, 1000),
                    model_id,
                ),
            )
            lot_id = cur.lastrowid

            for _ in range(boards_per_lot):
                # Mot phan board khong co loi nao (mo phong board OK / da qua kiem tra)
                has_defects = random.random() > empty_board_ratio
                n_defects = random.randint(1, defects_per_board_max) if has_defects else 0

                cur.execute(
                    "INSERT INTO tbBoard (defect_quantity, erro_quantity, tbLotid_lot) VALUES (?,?,?)",
                    (0, 0, lot_id),  # se update lai defect_quantity ben duoi sau khi sinh defect
                )
                board_id = cur.lastrowid

                ng_count = 0
                for _ in range(n_defects):
                    judgement = random.choice(JUDGEMENTS)
                    if judgement == "NG":
                        ng_count += 1
                    x_disp = round(random.uniform(0, 400), 1)
                    y_disp = round(random.uniform(0, 300), 1)
                    cur.execute(
                        """INSERT INTO tbDefect
                           (type, judgement, height, width, time, coordinates, url_image, tbBoardid_board, plc_coor)
                           VALUES (?,?,?,?,?,?,?,?,?)""",
                        (
                            random.choice(DEFECT_TYPES),
                            judgement,
                            round(random.uniform(3.0, 25.0), 1),
                            round(random.uniform(3.0, 15.0), 1),
                            random_time(),
                            f"{x_disp},{y_disp}",
                            "",
                            board_id,
                            random_plc_coor(plc_x_max, plc_y_max),
                        ),
                    )

                # Dong bo lai so lieu thong ke cho dung voi so defect vua sinh
                cur.execute(
                    "UPDATE tbBoard SET defect_quantity = ?, erro_quantity = ? WHERE id_board = ?",
                    (n_defects, ng_count, board_id),
                )

    conn.commit()


def print_summary(conn: sqlite3.Connection) -> None:
    cur = conn.cursor()
    for table in ("tbModel", "tbLot", "tbBoard", "tbDefect", "tbConfig"):
        cur.execute(f"SELECT COUNT(*) FROM {table}")
        print(f"  {table:10s}: {cur.fetchone()[0]} dong")


def main() -> None:
    parser = argparse.ArgumentParser(description="Sinh du lieu test cho autovrs.db")
    parser.add_argument("--db", default=DEFAULT_DB_PATH, help="Duong dan file autovrs.db")
    parser.add_argument("--models", type=int, default=3, help="So model moi can sinh them")
    parser.add_argument("--lots-per-model", type=int, default=2, help="So lot cho moi model")
    parser.add_argument("--boards-per-lot", type=int, default=5, help="So board cho moi lot")
    parser.add_argument(
        "--defects-per-board", type=int, default=5, help="So defect toi da cho moi board co loi"
    )
    parser.add_argument(
        "--empty-board-ratio",
        type=float,
        default=0.3,
        help="Ti le board KHONG co defect nao (0.0 - 1.0), mo phong board da OK",
    )
    parser.add_argument("--plc-x-max", type=float, default=364.0, help="Gioi han toa do X (PLC scale)")
    parser.add_argument("--plc-y-max", type=float, default=575.0, help="Gioi han toa do Y (PLC scale)")
    parser.add_argument("--seed", type=int, default=None, help="Random seed (de tai tao lai cung 1 bo du lieu)")
    parser.add_argument(
        "--reset",
        action="store_true",
        help="XOA SACH tbModel/tbLot/tbBoard/tbDefect truoc khi sinh moi (khong dung tbConfig)",
    )
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    db_dir = os.path.dirname(args.db)
    if db_dir and not os.path.exists(db_dir):
        os.makedirs(db_dir, exist_ok=True)

    if args.reset:
        confirm = input(
            f"XOA SACH toan bo tbModel/tbLot/tbBoard/tbDefect trong '{args.db}'? Go 'yes' de xac nhan: "
        )
        if confirm.strip().lower() != "yes":
            print("Da huy, khong xoa gi ca.")
            return

    conn = sqlite3.connect(args.db)
    try:
        create_tables(conn)
        if args.reset:
            reset_data(conn)
        ensure_default_config(conn)

        print(f"Dang sinh du lieu vao: {args.db}")
        generate(
            conn,
            n_models=args.models,
            lots_per_model=args.lots_per_model,
            boards_per_lot=args.boards_per_lot,
            defects_per_board_max=args.defects_per_board,
            empty_board_ratio=args.empty_board_ratio,
            plc_x_max=args.plc_x_max,
            plc_y_max=args.plc_y_max,
        )

        print("Xong. Tong so dong hien co trong database:")
        print_summary(conn)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
