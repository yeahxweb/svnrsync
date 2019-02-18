# svnrsync
Shell script to sync any svn projects to other svn projects. Source and destination project can be different svn server.
SVN同步工具（源与目标SVN可以在不同SVN服务器）

原理：
1. checkout源及目标SVN目录
2. rsync源到目标；
3. parallel多进程提高效率；
4. 作为作业执行时通过加锁避免冲突；

使用步骤：
1. 修改svnrsync.cfg中的配置
	1）SVN命令的路径；
	2）源SVN及目标SVN的用户名、密码（base64编码）；
	3）指定用于加锁的文件的目录；
	4）源SVN及目标SVN的本地目录以及服务器地址；
	5）需要进行同步的目录编号；
2. svnrsync.sh中指定svnrsync.cfg的目录；
3. 源SVN checkout到指定的本地目录；
4. 目标SVN checkout到指定的本地目录；
5. 运行svnrsync.sh进行SVN同步；
6. 把svnrsync.sh配置到crontab中；
