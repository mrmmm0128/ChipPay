import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/admin_dashboard_screen.dart';
import 'package:yourpay/appadmin/agent/agent_list.dart';

class AgenciesView extends StatelessWidget {
  final String query;
  final AgenciesTab tab;
  final ValueChanged<AgenciesTab> onTabChanged;

  const AgenciesView({
    required this.query,
    required this.tab,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 代理店ビュー内のサブ切替（必要なら拡張）
        const Divider(height: 1),
        Expanded(child: AgentsList(query: query)),
      ],
    );
  }
}
