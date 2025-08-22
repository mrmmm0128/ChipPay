import 'package:flutter/material.dart';

class StoreCard extends StatelessWidget {
  final String id;
  final String name;
  final String status;
  final String creator;
  final bool isNew;
  final VoidCallback onTap;

  const StoreCard({
    required this.id,
    required this.name,
    required this.status,
    required this.creator,
    required this.isNew,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final caption = const TextStyle(color: Colors.black54, fontSize: 12.5);

    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: const Color(0x1A000000), // 黒10%影
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 18,
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                child: Icon(Icons.storefront, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 店舗名
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // ID と ステータス
                    Text(
                      'ID: $id  •  $status',
                      style: caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (creator.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '作成: $creator',
                        style: caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (isNew)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'NEW',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, color: Colors.black45),
            ],
          ),
        ),
      ),
    );
  }
}
