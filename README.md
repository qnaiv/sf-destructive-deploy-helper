# sf-destructive-deploy-helper

## 概要
`sf-destructive-deploy-helper` は、Salesforceのデプロイにおける破壊的変更（リソース削除）時に発生しがちな依存関係エラーを自動で解決するためのCLIツールです。

このツールは、以下の2つの主要なアプローチをサポートする予定です。

1.  **Git差分ベース (Git Diff Based)**: Gitブランチ間の差分を基にデプロイパッケージを生成し、破壊的変更の依存関係を自動で解決します。
2.  **組織スナップショット比較ベース (Org Snapshot Comparison Based)**: Salesforce組織の現在の状態とローカルソースコードの差分を比較し、デプロイパッケージを生成します。

## 特徴
- 破壊的変更時の依存関係エラーを自動で検出し、一時的に無害化（コメントアウトなど）してデプロイを成功させます。
- `sfdx-git-delta` を活用し、効率的な差分ベースのデプロイをサポートします。
- （将来的に）Salesforce組織との直接比較によるデプロイもサポートします。

## 前提条件
- [Salesforce CLI](https://developer.salesforce.com/tools/sfdxcli) がインストールされていること。
- [Git](https://git-scm.com/) がインストールされていること。
- `sfdx-git-delta` プラグインがインストールされていること。
  ```bash
  sf plugins install sfdx-git-delta
  ```

## 使用方法

### Git差分ベースのデプロイ (デフォルトモード)

開発ブランチから本番ブランチへのデプロイなど、Gitの差分に基づいてデプロイを行う場合に使用します。

```bash
./sfdx-deploy-helper.sh -o <ターゲット組織エイリアス> -b <比較元ブランチ名>
```

**例:**
`develop` ブランチから `main` ブランチへの差分を `my-prod-org` という組織にデプロイする場合。

```bash
./sfdx-deploy-helper.sh -o my-prod-org -b main
```

### 組織スナップショット比較ベースのデプロイ (開発中)

（この機能は現在開発中です。完成後、詳細な使用方法が追加されます。）

```bash
./sfdx-deploy-helper.sh -o <ターゲット組織エイリアス> -m org-snapshot
```

## 開発計画
詳細は `salesforce_deployment_strategies_tasks.md` を参照してください。
