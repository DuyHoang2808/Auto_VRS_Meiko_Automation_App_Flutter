import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/statistics_provider.dart';

class SelectLotScreen extends StatefulWidget {
  const SelectLotScreen({super.key});

  @override
  State<SelectLotScreen> createState() => _SelectLotScreenState();
}

class _SelectLotScreenState extends State<SelectLotScreen> {
  @override
  void initState() {
    super.initState();
    // Ensure data is loaded
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = Provider.of<StatisticsProvider>(context, listen: false);
      if (!provider.isLoading && provider.lots.isEmpty) {
        provider.initialize();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Consumer<StatisticsProvider>(
              builder: (context, statsProvider, child) {
                if (statsProvider.isLoading) {
                  return const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Đang tải dữ liệu lô hàng...'),
                    ],
                  );
                }

                if (statsProvider.lots.isEmpty) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inventory_2_outlined,
                        size: 64,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Không có lô hàng nào',
                        style: TextStyle(
                          fontSize: 18,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Chưa có dữ liệu lô hàng nào được tạo',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Chọn lô hàng để xem thống kê lỗi',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${statsProvider.lots.length} lô',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Xem tổng tất cả các lô - không truyền ?lot
                    Card(
                      elevation: 2,
                      color: Colors.blue.shade50,
                      child: ListTile(
                        leading: const Icon(Icons.select_all),
                        title: const Text(
                          'Tất cả các lô',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: const Text(
                          'Gộp toàn bộ lỗi của mọi lô, mọi model',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: const Icon(Icons.arrow_forward_ios),
                        onTap: () => context.push('/defect-type'),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: statsProvider.lots.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final lot = statsProvider.lots[index];
                          return Card(
                            elevation: 2,
                            child: ListTile(
                              title: Text(
                                lot['lot_id'] ?? 'Unknown Lot',
                                style: const TextStyle(fontWeight: FontWeight.w500),
                              ),
                              subtitle: Text(
                                'Model: ${lot['model_id'] ?? 'Unknown'} | Tổng: ${lot['total_boards'] ?? 0} boards',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              trailing: const Icon(Icons.arrow_forward_ios),
                              // Phải truyền id_lot, nếu không màn thống kê hiện
                              // số tổng của toàn bộ DB bất kể chọn lô nào.
                              onTap: () => context.push(
                                '/defect-type?lot=${lot['id_lot']}',
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
