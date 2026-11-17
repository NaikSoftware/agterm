import 'dart:convert';

const linkUpgradeRequest = '{"mux":1}\n';

bool isLinkUpgradeAnswer(String line) {
  try {
    final o = jsonDecode(line);
    return o is Map && o['ok'] == true && o['mux'] == 1;
  } on FormatException {
    return false;
  }
}
