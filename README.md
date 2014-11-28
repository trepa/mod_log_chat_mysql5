mod_log_chat_mysql
============

Developed by Jérôme Sautret <jerome.sautret@process-one.net>, Adapted for DB Logging by Michael Weibel <michael.weibel@amiadogroup.com>.

Prerequisite
============
In order to compile Emysql, Erlang R13 or newer will need to be installed.
If you are using the 2.1.10 ejabberd installer, that comes with an old version of Erlang and you will not be able to compile Emysql.

Installation
============
  * Download Emysql: https://github.com/Eonblast/Emysql
  * cd Emysql && make
  * Make sure that emysql.app is present in the Emysql/ebin folder. If not build the Emysql module again.
  * In another directory download ejabbed-modules from subversion: svn co https://svn.process-one.net/ejabberd-modules
  * Copy Emysql/ebin/* to your ejabberd-modules (ebin) folder: cp Emysql/ebin/* ejabberd-modules/ejabberd-dev/trunk/ebin/
  * Download mod_log_chat_mysql5 : git clone https://github.com/candy-chat/mod_log_chat_mysql5.git
  * Move the mod_log_chat_mysql5 directory into the root of the ejabberd-modules folder
  * Navigate to the mod_log_chat_mysql5 directory in the ejabberd-modules folder and call ./build.sh
  * If successful the module has been compiled and output to ebin/mod_log_chat_mysql5.beam. Copy this file to your ejabberd system ebin folder folder (e.g. /usr/lib/ejabberd/ebin on Debian)
  * Copy all the Emysql files to your ejabberd system ebin folder as well. (Emysql/ebin/*)
  * Create required mysql table like this

```sql
  CREATE TABLE `mod_log_chat` ( 
    `id` Int( 11 ) AUTO_INCREMENT NOT NULL, 
    `fromJid` VarChar( 255 ) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL, 
    `toJid` VarChar( 255 ) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL, 
    `sentDate` Timestamp NOT NULL ON UPDATE CURRENT_TIMESTAMP DEFAULT CURRENT_TIMESTAMP, 
    `body` Text CHARACTER SET utf8 COLLATE utf8_general_ci NULL, 
    `type` VarChar( 10 ) CHARACTER SET utf8 COLLATE utf8_general_ci NULL, 
    `msg_id` VarChar( 255 ) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
    `time` BigInt( 255 ) UNSIGNED NOT NULL,
     PRIMARY KEY ( `id` )
  ) ENGINE = InnoDB CHARACTER SET = utf8;

CREATE TABLE `mod_log_image` ( 
  `msg_id` VarChar( 255 ) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL, 
  `image` VarChar( 255 ) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
   PRIMARY KEY ( `msg_id` )
, CONSTRAINT `unique_msg_id` UNIQUE( `msg_id` ) )
ENGINE = InnoDB CHARACTER SET = utf8;
CREATE UNIQUE INDEX `iamge` ON `mod_log_image`( `msg_id` );
```
  * See conf/ejabberd.conf.sample for an example configuration
  * Once the ejabberd module is loaded and you have started ejabberd.  Look at the log files to see if the module has been correctly started (erlang.log) 
