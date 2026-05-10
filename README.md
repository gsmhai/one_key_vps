

1.下载脚本到服务器
  curl -O https://raw.githubusercontent.com/gsmhai/one_key_vps/blob/main/vmess.sh
  chmod +x vmess.sh
2.如果想修改web面板的用户名和密码，手动编辑文件开头的用户名和密码，默认用户名密码都为:admin
  PANEL_USER="admin"        # 面板登录用户名
  PANEL_PASS="admin"  # 面板登录密码
2. 执行脚本
  bash xray-setup.sh
