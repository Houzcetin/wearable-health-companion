import 'package:flutter/material.dart';

class DeleteDataDialog extends StatefulWidget {
  const DeleteDataDialog({super.key, required this.account});
  final bool account;
  @override
  State<DeleteDataDialog> createState() => _DeleteDataDialogState();
}

class _DeleteDataDialogState extends State<DeleteDataDialog> {
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.account ? 'Delete account?' : 'Delete health data?'),
    content: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.account
            ? 'This permanently deletes your account, health data and coach history. '
              'Type DELETE to confirm.'
            : 'This disconnects Google Health and permanently deletes your synced data, '
              'demo data and coach history. Your account stays.'),
        if (widget.account)
          TextField(
            key: const Key('delete-account-confirmation'),
            controller: _confirmation,
            decoration: const InputDecoration(labelText: 'Type DELETE'),
            onChanged: (_) => setState(() {}),
          ),
      ]),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel')),
      FilledButton(
        key: const Key('confirm-delete'),
        onPressed: widget.account && _confirmation.text != 'DELETE'
            ? null : () => Navigator.pop(context, true),
        child: const Text('Delete'),
      ),
    ],
  );
}
