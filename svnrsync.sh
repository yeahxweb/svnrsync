#!/usr/bin/env bash

source /etc/profile
source /PATH_TO_CONFIGFILE/svnrsync.cfg

crstr=$"\n"

function Print()
{
	datestr=$(date +"%Y-%m-%d %H:%M:%S")
	echo -e "[$datestr] $1 $2 $3"
}

function LockFile()
{
	#以文件作为锁，输出1加锁
	echo "1" > $LOCK_DIR/$svnnum
	Print "SVN同步任务加锁：$localfilename$crstr" 2>&1 >> "$logfile"
}

function UnlockExit()
{
	#以文件作为锁，输出0解锁
	echo "0" > $LOCK_DIR/$svnnum
	Print "SVN同步任务解锁：$localfilename$crstr" 2>&1 >> "$logfile"
	exit;
}

scriptfile=$(readlink -f "$0")
pathname=$(dirname "$scriptfile")

SVN_SRC_PASSWD_STR=$(echo $SVN_SRC_PASSWD | base64 -di)
SVN_DEST_PASSWD_STR=$(echo $SVN_DEST_PASSWD | base64 -di)

#获取第一个参数，作为SVN列表中的序号
svnnum=$1
localsvnsrcstr=SVN_SRC_$svnnum
localsvnsrc=${!localsvnsrcstr}
localsvnsrcsvrstr=SVN_SRC_SVR_$svnnum
localsvnsrcsvr=${!localsvnsrcsvrstr}
localsvndeststr=SVN_DEST_$svnnum
localsvndest=${!localsvndeststr}
localsvndestsvrstr=SVN_DEST_SVR_$svnnum
localsvndestsvr=${!localsvndestsvrstr}
localfilename=$(basename $localsvnsrc)
logfile="$pathname/$localfilename.log"

{
	Print "svnrsync：SVN同步任务开始！" 2>&1 >> "$logfile"

	#判断锁文件是否存在，若不存在，则生成一个
	if [ ! -f $LOCK_DIR/$svnnum ]; then
		LockFile
	else
	#判断若文件已存在，则已经有进程在进行同步操作
		lockstr=$(head -n 1 $LOCK_DIR/$svnnum)
		if [[ $lockstr == "1" ]]; then
			Print "已有进程正在进行SVN同步！退出！" 2>&1 >> "$logfile"
			exit;
		else
			LockFile
		fi
	fi

	Print "$localfilename：SVN同步开始！" 2>&1 >> "$logfile"

	#判断来源目录的svn url和配置的svn url是否一致
	srcreporooturl=$($SVN_BIN info $localsvnsrc | grep "Repository Root:" | awk -F ' ' '{print $3}') 2>&1 >> "$logfile"
	Print "来源SVN目录的版本库ROOT URL：$srcreporooturl" 2>&1 >> "$logfile"
	if [[ $localsvnsrcsvr != $srcreporooturl* ]]; then
		Print "来源SVN目录的版本库ROOT URL与配置不一致，退出！$crstr" 2>&1 >> "$logfile"
		#输出0解锁，并退出
		UnlockExit
	fi

	#判断目标目录的svn url和配置的svn url是否一致
	destreporooturl=$($SVN_BIN info $localsvndest | grep "Repository Root:" | awk -F ' ' '{print $3}') 2>&1 >> "$logfile"
	Print "目标SVN目录的版本库ROOT URL：$destreporooturl" 2>&1 >> "$logfile"
	if [[ $localsvndestsvr != $destreporooturl* ]]; then
		Print "目标SVN目录的版本库ROOT URL与配置不一致，退出！$crstr" 2>&1 >> "$logfile"
		#输出0解锁，并退出
		UnlockExit
	fi

	#检查本地子目录的版本号与服务器的版本号
	srclocalrev=$($SVN_BIN info "$localsvnsrc" | grep "Revision:" | awk -F ' ' '{print $2}') 2>&1 >> "$logfile"
	srcserverrev=$($SVN_BIN info "$localsvnsrcsvr" --username $SVN_SRC_USER --password $SVN_SRC_PASSWD_STR | grep "Revision:" | awk -F ' ' '{print $2}') 2>&1 >> "$logfile"
	Print "来源SVN目录的版本号：$srclocalrev" 2>&1 >> "$logfile"
	Print "来源SVN目录的服务端的版本号：$srcserverrev" 2>&1 >> "$logfile"
	if [[ $srclocalrev -ge $srcserverrev ]]; then
		Print "来源SVN目录的版本号与服务端的版本号相同，无须同步，退出！$crstr" 2>&1 >> "$logfile"
		#输出0解锁，并退出
		UnlockExit
	fi

	#更新目标SVN目录到最新版本
	destrevupdatedir=$($SVN_BIN update "$localsvndest" --username $SVN_DEST_USER --password $SVN_DEST_PASSWD_STR) 2>&1 >> "$logfile"
	Print "更新目标SVN目录到最新版本：$crstr$destrevupdatedir" 2>&1 >> "$logfile"

	#如果SYNC_STEP配置不为0，并且srclocalrev与srcserverrev版本号相差大于SYNC_MAX_VERSION，则最多只更新SYNC_MAX_VERSION版本号
	if [[ ($SYNC_STEP != 0) && $((SYNC_MAX_VERSION + srclocalrev)) -lt $srcserverrev ]]; then
		srcserverrev=$((SYNC_MAX_VERSION + srclocalrev))
	fi

	#用于判断前一次循环检查是否有变更，默认为有变更
	ischange=1
	
	#逐个版本更新来源SVN目录，并同步到目标SVN目录，再提交
	while [[ $srclocalrev -lt $srcserverrev ]]; do
		#如果SYNC_STEP配置为0，则不进行逐个版本号的更新与同步，直接更新同步到最新的版本
		if [[ $SYNC_STEP == 0 ]]; then
			srclocalrev=$srcserverrev
		else
			(( srclocalrev ++ ))
		fi
		
		srcrevlog=$($SVN_BIN log "$localsvnsrcsvr" -v -r $srclocalrev --username $SVN_SRC_USER --password $SVN_SRC_PASSWD_STR | sed -e '1d' -e '$d') 2>&1 >> "$logfile"
		if [[ -z "$srcrevlog" ]]; then
			Print "来源SVN目录的版本号：$srclocalrev，没有变更，continue！" 2>&1 >> "$logfile"
			ischange=0
			continue;
		else
			ischange=1
		fi
		
		Print "来源SVN目录的版本号：${srclocalrev}，获取提交日志：$crstr$srcrevlog" 2>&1 >> "$logfile"

		svncopyline=`echo "$srcrevlog" | grep " (from /" | grep ':*)$'`
		svncopylinecount=`echo -n "$svncopyline" | grep -c '^'`
	  if [[ ( ! -z "$svncopyline" ) && ( 1 -eq $svncopylinecount ) ]]; then
	  	svncopylinearry=($svncopyline)
	  	svncopyto="$srcreporooturl${svncopylinearry[1]}"
	  	svncopyfromdir=`echo "${svncopylinearry[3]}" | awk -F ':' '{print $1}'`
	  	svncopyfrom="$srcreporooturl$svncopyfromdir"
	  	subdirto=${svncopyto/#$localsvnsrcsvr/}
	  	subdirfrom=${svncopyfrom/#$localsvnsrcsvr/}
	  	
	  	svncopy=$($SVN_BIN copy "$localsvndestsvr$subdirfrom" "$localsvndestsvr$subdirto" -m $"Sync From SVN: ${localsvnsrcsvr}，
$srcrevlog" --username $SVN_SRC_USER --password $SVN_SRC_PASSWD_STR)
	    	Print "SVN COPY，来源目录：$localsvndestsvr$subdirfrom，目标目录：$localsvndestsvr$subdirto，执行结果：$svncopy" 2>&1 >> "$logfile"
	    	
	    	#更新来源SVN目录到最新版本
	    	srcrevupdate=$($SVN_BIN update "$localsvnsrc" -r $srclocalrev --username $SVN_SRC_USER --password $SVN_SRC_PASSWD_STR) 2>&1 >> "$logfile"
	    	Print "更新来源SVN目录到指定版本号：${srclocalrev}，更新：$crstr$srcrevupdate" 2>&1 >> "$logfile"
	    	
	    	#更新目标SVN目录到最新版本
	    	destrevupdatedir=$($SVN_BIN update "$localsvndest" --username $SVN_DEST_USER --password $SVN_DEST_PASSWD_STR) 2>&1 >> "$logfile"
	    	Print "更新目标SVN目录到最新版本：$crstr$destrevupdatedir" 2>&1 >> "$logfile"
	    	
	    	continue;
	    fi

			srcrevupdate=$($SVN_BIN update "$localsvnsrc" -r $srclocalrev --username $SVN_SRC_USER --password $SVN_SRC_PASSWD_STR) 2>&1 >> "$logfile"
			Print "更新来源SVN目录到指定版本号：${srclocalrev}，更新：$crstr$srcrevupdate" 2>&1 >> "$logfile"

			syncsrcdest=$(ls "$localsvnsrc" | $PARALLEL_BIN -j2 $RSYNC_BIN -av --delete "$localsvnsrc/{}" "$localsvndest" --exclude=.svn) 2>&1 >> "$logfile"
			Print "RSYNC同步来源SVN目录到目标SVN目录：$crstr$syncsrcdest" 2>&1 >> "$logfile"
			
			svn_special_files=`$SVN_BIN propget --recursive svn:special "$localsvndest" | cut -d' ' -f1`
			link_files=`find "$localsvndest" -type l`
			diff_files=`echo $link_files $svn_special_files | tr " " "\n" | sort | uniq -u`
			for i in $diff_files; do
			        Print "修改链接文件的SVN属性为svn:special：$i" 2>&1 >> "$logfile"
			        /opt/csvn/bin/svn propset svn:special '*' "$i"
			done

			svnadddest=$($SVN_BIN add "$localsvndest" --force) 2>&1 >> "$logfile"
			Print "目标SVN目录ADD文件：$crstr$svnadddest" 2>&1 >> "$logfile"
			
			svndeldest=`$SVN_BIN status "$localsvndest" | $PARALLEL_BIN --pipe -N5000 -j4 grep ^! | cut -c 9- | sed 's/^/"/g;s/$/"/g' | xargs $SVN_BIN rm`
			Print "目标SVN目录DEL文件：$crstr$svndeldest" 2>&1 >> "$logfile"
			
			destrevcommit=$($SVN_BIN commit -m $"Sync From SVN: ${localsvnsrcsvr}，
$srcrevlog" "$localsvndest"  --username $SVN_DEST_USER --password $SVN_DEST_PASSWD_STR) 2>&1 >> "$logfile"
			Print "目标SVN目录提交：$crstr$destrevcommit" 2>&1 >> "$logfile"
	done
	
	#如果之前的循环检查没有变更，则进行一次更新，到最新版本
	if [[ $ischange == 0 ]]; then
		#更新来源SVN目录到最新版本
  	srcrevupdate=$($SVN_BIN update "$localsvnsrc" -r $srclocalrev --username $SVN_SRC_USER --password $SVN_SRC_PASSWD_STR) 2>&1 >> "$logfile"
  	Print "更新来源SVN目录到指定版本号：${srclocalrev}，更新：$crstr$srcrevupdate" 2>&1 >> "$logfile"
	fi

	Print "目录更新并同步提交成功：$localsvnsrc$crstr" 2>&1 >> "$logfile"
	#输出0解锁，并退出
	UnlockExit
} || {
	Print "SVN同步任务异常退出：$localfilename" 2>&1 >> "$logfile"
	UnlockExit
}


