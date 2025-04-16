// Chat Auto Backup 插件 - 自动保存和恢复最近三次聊天记录
// 主要功能：
// 1. 自动保存最近聊天记录到IndexedDB (基于事件触发, 区分立即与防抖)
// 2. 在插件页面显示保存的记录
// 3. 提供恢复功能，将保存的聊天记录恢复到新的聊天中
// 4. 使用Web Worker优化深拷贝性能

import {
    getContext,
    renderExtensionTemplateAsync,
    extension_settings,
} from '../../../extensions.js';

import {
    saveSettingsDebounced,
    eventSource,
    event_types,
} from '../../../../script.js';

// 扩展名和设置初始化
const PLUGIN_NAME = 'chat-history-backup';
const DEFAULT_SETTINGS = {
    maxBackupsPerChat: 3,  // 每个聊天保存的最大备份数量
    debug: true,           // 调试模式
};

// IndexedDB 数据库名称和版本
const DB_NAME = 'ST_ChatAutoBackup';
const DB_VERSION = 1;
const STORE_NAME = 'backups';

// Web Worker 实例 (稍后初始化)
let backupWorker = null;
// 用于追踪 Worker 请求的 Promise
const workerPromises = {};
let workerRequestId = 0;

// 数据库连接池 - 实现单例模式
let dbConnection = null;

// --- 深拷贝逻辑 (将在Worker和主线程中使用) ---
// 注意：此函数现在需要在 Worker 的作用域内可用
const deepCopyLogicString = `
    const deepCopy = (obj) => {
        try {
            // console.log('[聊天自动备份 Worker] 开始执行 structuredClone'); // Worker日志可能不易查看
            return structuredClone(obj);
        } catch (error) {
            // console.warn('[聊天自动备份 Worker] structuredClone 失败，回退到 JSON 方法', error);
            // 在Worker中 console.warn 可能不直接显示在主控制台
            try {
                return JSON.parse(JSON.stringify(obj));
            } catch (jsonError) {
                // console.error('[聊天自动备份 Worker] JSON 深拷贝也失败:', jsonError);
                throw jsonError; // 抛出错误，让主线程知道
            }
        }
    };
`;

// --- 日志函数 ---
function logDebug(...args) {
    const settings = extension_settings[PLUGIN_NAME];
    if (settings && settings.debug) {
        console.log('[聊天自动备份]', ...args);
    }
}

// --- 设置初始化 ---
function initSettings() {
    console.log('[聊天自动备份] 初始化插件设置');
    if (!extension_settings[PLUGIN_NAME]) {
        console.log('[聊天自动备份] 创建新的插件设置');
        extension_settings[PLUGIN_NAME] = { ...DEFAULT_SETTINGS }; // 使用扩展运算符创建副本
    }

    // 确保设置结构完整
    const settings = extension_settings[PLUGIN_NAME];
    settings.maxBackupsPerChat = settings.maxBackupsPerChat ?? DEFAULT_SETTINGS.maxBackupsPerChat;
    settings.debug = settings.debug ?? DEFAULT_SETTINGS.debug;

    console.log('[聊天自动备份] 插件设置初始化完成:', settings);
    return settings;
}

// --- IndexedDB 相关函数 (优化版本) ---
// 初始化 IndexedDB 数据库
function initDatabase() {
    return new Promise((resolve, reject) => {
        logDebug('初始化 IndexedDB 数据库');
        const request = indexedDB.open(DB_NAME, DB_VERSION);

        request.onerror = function(event) {
            console.error('[聊天自动备份] 打开数据库失败:', event.target.error);
            reject(event.target.error);
        };

        request.onsuccess = function(event) {
            const db = event.target.result;
            logDebug('数据库打开成功');
            resolve(db);
        };

        request.onupgradeneeded = function(event) {
            const db = event.target.result;
            console.log('[聊天自动备份] 数据库升级中，创建对象存储');
            if (!db.objectStoreNames.contains(STORE_NAME)) {
                const store = db.createObjectStore(STORE_NAME, { keyPath: ['chatKey', 'timestamp'] });
                store.createIndex('chatKey', 'chatKey', { unique: false });
                console.log('[聊天自动备份] 创建了备份存储和索引');
            }
        };
    });
}

// 获取数据库连接 (优化版本 - 使用连接池)
async function getDB() {
    try {
        // 检查现有连接是否可用
        if (dbConnection && dbConnection.readyState !== 'closed') {
            return dbConnection;
        }
        
        // 创建新连接
        dbConnection = await initDatabase();
        return dbConnection;
    } catch (error) {
        console.error('[聊天自动备份] 获取数据库连接失败:', error);
        throw error;
    }
}

// 保存备份到 IndexedDB (优化版本)
async function saveBackupToDB(backup) {
    const db = await getDB();
    try {
        await new Promise((resolve, reject) => {
            const transaction = db.transaction([STORE_NAME], 'readwrite');
            
            transaction.oncomplete = () => {
                logDebug(`备份已保存到IndexedDB, 键: [${backup.chatKey}, ${backup.timestamp}]`);
                resolve();
            };
            
            transaction.onerror = (event) => {
                console.error('[聊天自动备份] 保存备份事务失败:', event.target.error);
                reject(event.target.error);
            };
            
            const store = transaction.objectStore(STORE_NAME);
            store.put(backup);
        });
    } catch (error) {
        console.error('[聊天自动备份] saveBackupToDB 失败:', error);
        throw error;
    }
}

// 从 IndexedDB 获取指定聊天的所有备份 (优化版本)
async function getBackupsForChat(chatKey) {
    const db = await getDB();
    try {
        return await new Promise((resolve, reject) => {
            const transaction = db.transaction([STORE_NAME], 'readonly');
            
            transaction.onerror = (event) => {
                console.error('[聊天自动备份] 获取备份事务失败:', event.target.error);
                reject(event.target.error);
            };
            
            const store = transaction.objectStore(STORE_NAME);
            const index = store.index('chatKey');
            const request = index.getAll(chatKey);
            
            request.onsuccess = () => {
                const backups = request.result || [];
                logDebug(`从IndexedDB获取了 ${backups.length} 个备份，chatKey: ${chatKey}`);
                resolve(backups);
            };
            
            request.onerror = (event) => {
                console.error('[聊天自动备份] 获取备份失败:', event.target.error);
                reject(event.target.error);
            };
        });
    } catch (error) {
        console.error('[聊天自动备份] getBackupsForChat 失败:', error);
        return []; // 出错时返回空数组
    }
}

// 从 IndexedDB 获取所有备份 (优化版本)
async function getAllBackups() {
    const db = await getDB();
    try {
        return await new Promise((resolve, reject) => {
            const transaction = db.transaction([STORE_NAME], 'readonly');
            
            transaction.onerror = (event) => {
                console.error('[聊天自动备份] 获取所有备份事务失败:', event.target.error);
                reject(event.target.error);
            };
            
            const store = transaction.objectStore(STORE_NAME);
            const request = store.getAll();
            
            request.onsuccess = () => {
                const backups = request.result || [];
                logDebug(`从IndexedDB获取了总共 ${backups.length} 个备份`);
                resolve(backups);
            };
            
            request.onerror = (event) => {
                console.error('[聊天自动备份] 获取所有备份失败:', event.target.error);
                reject(event.target.error);
            };
        });
    } catch (error) {
        console.error('[聊天自动备份] getAllBackups 失败:', error);
        return [];
    }
}

// 从 IndexedDB 删除指定备份 (优化版本)
async function deleteBackup(chatKey, timestamp) {
    const db = await getDB();
    try {
        await new Promise((resolve, reject) => {
            const transaction = db.transaction([STORE_NAME], 'readwrite');
            
            transaction.oncomplete = () => {
                logDebug(`已从IndexedDB删除备份, 键: [${chatKey}, ${timestamp}]`);
                resolve();
            };
            
            transaction.onerror = (event) => {
                console.error('[聊天自动备份] 删除备份事务失败:', event.target.error);
                reject(event.target.error);
            };
            
            const store = transaction.objectStore(STORE_NAME);
            store.delete([chatKey, timestamp]);
        });
    } catch (error) {
        console.error('[聊天自动备份] deleteBackup 失败:', error);
        throw error;
    }
}

// --- 聊天信息获取 (保持不变) ---
function getCurrentChatKey() {
    const context = getContext();
    logDebug('获取当前聊天标识符, context:',
        {groupId: context.groupId, characterId: context.characterId, chatId: context.chatId});
    if (context.groupId) {
        const key = `group_${context.groupId}_${context.chatId}`;
        logDebug('当前是群组聊天，chatKey:', key);
        return key;
    } else if (context.characterId !== undefined && context.chatId) { // 确保chatId存在
        const key = `char_${context.characterId}_${context.chatId}`;
        logDebug('当前是角色聊天，chatKey:', key);
        return key;
    }
    console.warn('[聊天自动备份] 无法获取当前聊天的有效标识符 (可能未选择角色/群组或聊天)');
    return null;
}

function getCurrentChatInfo() {
    const context = getContext();
    let chatName = '当前聊天', entityName = '未知';

    if (context.groupId) {
        const group = context.groups?.find(g => g.id === context.groupId);
        entityName = group ? group.name : `群组 ${context.groupId}`;
        chatName = context.chatId || '新聊天'; // 使用更明确的默认名
        logDebug('获取到群组聊天信息:', {entityName, chatName});
    } else if (context.characterId !== undefined) {
        entityName = context.name2 || `角色 ${context.characterId}`;
        const character = context.characters?.[context.characterId];
        if (character && context.chatId) {
             // chat文件名可能包含路径，只取最后一部分
             const chatFile = character.chat || context.chatId;
             chatName = chatFile.substring(chatFile.lastIndexOf('/') + 1).replace('.jsonl', '');
        } else {
            chatName = context.chatId || '新聊天';
        }
        logDebug('获取到角色聊天信息:', {entityName, chatName});
    } else {
        console.warn('[聊天自动备份] 无法获取聊天实体信息，使用默认值');
    }

    return { entityName, chatName };
}

// --- Web Worker 通信 ---
// 发送数据到 Worker 并返回包含拷贝后数据的 Promise
function performDeepCopyInWorker(chat, metadata) {
    return new Promise((resolve, reject) => {
        if (!backupWorker) {
            return reject(new Error("Backup worker not initialized."));
        }

        const currentRequestId = ++workerRequestId;
        workerPromises[currentRequestId] = { resolve, reject };

        logDebug(`[主线程] 发送数据到 Worker (ID: ${currentRequestId}), Chat长度: ${chat?.length}`);
        try {
             // 只发送需要拷贝的数据，减少序列化开销
            backupWorker.postMessage({
                id: currentRequestId,
                payload: { chat, metadata }
            });
        } catch (error) {
             console.error(`[主线程] 发送消息到 Worker 失败 (ID: ${currentRequestId}):`, error);
             delete workerPromises[currentRequestId];
             reject(error);
        }
    });
}

// --- 核心备份逻辑 (使用改进的事务管理方案) ---
async function performBackup() {
    const currentTimestamp = Date.now(); // 在开始时获取时间戳
    logDebug(`[主线程] 开始执行聊天备份 @ ${new Date(currentTimestamp).toLocaleTimeString()}`);

    // 1. 前置检查
    const chatKey = getCurrentChatKey();
    if (!chatKey) {
        console.warn('[聊天自动备份] 无有效的聊天标识符，取消备份');
        return;
    }

    const context = getContext();
    const { chat, chat_metadata } = context;

    if (!chat || chat.length === 0) {
        logDebug('[聊天自动备份] 聊天记录为空，取消备份');
        return;
    }

    const settings = extension_settings[PLUGIN_NAME];
    const { entityName, chatName } = getCurrentChatInfo();
    const lastMsgIndex = chat.length - 1;
    const lastMessage = chat[lastMsgIndex];
    const lastMessagePreview = lastMessage?.mes?.substring(0, 100) || '(空消息)';

    logDebug(`准备备份聊天: ${entityName} - ${chatName}, 消息数: ${chat.length}, 最后消息ID: ${lastMsgIndex}`);

    try {
        // 2. 使用 Worker 进行深拷贝 (事务外)
        console.time('[聊天自动备份] Web Worker 深拷贝时间');
        logDebug('[主线程] 请求 Worker 执行深拷贝...');
        const { chat: copiedChat, metadata: copiedMetadata } = await performDeepCopyInWorker(chat, chat_metadata);
        console.timeEnd('[聊天自动备份] Web Worker 深拷贝时间');
        logDebug('[主线程] 从 Worker 收到拷贝后的数据');

        if (!copiedChat) {
             throw new Error("Worker did not return valid copied chat data.");
        }

        // 3. 构建备份对象 (事务外)
        const backup = {
            timestamp: currentTimestamp, // 使用开始时的时间戳
            chatKey,
            entityName,
            chatName,
            lastMessageId: lastMsgIndex,
            lastMessagePreview,
            chat: copiedChat, // 使用 Worker 返回的拷贝
            metadata: copiedMetadata || {} // 使用 Worker 返回的拷贝
        };

        // 4. 获取现有备份 (单独事务)
        const existingBackups = await getBackupsForChat(chatKey);
        
        // 5. 检查重复 (事务外)
        const existingBackupIndex = existingBackups.findIndex(b => b.lastMessageId === lastMsgIndex);

        if (existingBackupIndex !== -1) {
             // 比较时间戳，仅当新备份更新时才替换
            if (backup.timestamp > existingBackups[existingBackupIndex].timestamp) {
                logDebug(`发现具有相同最后消息ID (${lastMsgIndex}) 的旧备份，将删除旧备份`);
                // 6. 删除旧的重复备份 (单独事务)
                await deleteBackup(chatKey, existingBackups[existingBackupIndex].timestamp);
                existingBackups.splice(existingBackupIndex, 1); // 从列表中移除旧备份
            } else {
                logDebug(`发现具有相同最后消息ID (${lastMsgIndex}) 且时间戳更新或相同的备份，跳过本次保存`);
                return; // 不保存这个备份
            }
        }

        // 7. 保存新备份到 IndexedDB (单独事务)
        await saveBackupToDB(backup);

        // 8. 清理旧备份，确保不超过数量限制 (可能多个单独事务)
        // 将新备份添加到考虑列表
        const allChatBackups = [...existingBackups, backup]; // 现在列表包含了最新的备份
        allChatBackups.sort((a, b) => b.timestamp - a.timestamp); // 按时间降序排序

        if (allChatBackups.length > settings.maxBackupsPerChat) {
            logDebug(`备份数量 (${allChatBackups.length}) 超出限制 (${settings.maxBackupsPerChat})，准备删除旧备份`);
            const backupsToDelete = allChatBackups.slice(settings.maxBackupsPerChat);
            // 使用Promise.all并行删除，提高效率
            await Promise.all(backupsToDelete.map(oldBackup => {
                logDebug(`删除旧备份: 时间 ${new Date(oldBackup.timestamp).toLocaleString()}, 最后消息ID ${oldBackup.lastMessageId}`);
                return deleteBackup(oldBackup.chatKey, oldBackup.timestamp);
            }));
        }

        // 9. UI提示 (可选)
        if (settings.debug) {
            toastr.info(`已备份聊天: ${entityName} (${lastMsgIndex + 1}条消息)`, '聊天自动备份');
        }
        logDebug(`成功完成聊天备份: ${entityName} - ${chatName}`);

    } catch (error) {
        console.error('[聊天自动备份] 备份过程中发生严重错误:', error);
        toastr.error(`备份失败: ${error.message}`, '聊天自动备份'); // 向用户显示错误
    }
}

// --- 防抖函数 ---
function createDebouncedBackup(delay = 2000) {
    console.log('[聊天自动备份] 创建防抖备份函数');
    let timeout;
    // 返回一个 async 函数以正确处理 performBackup 的 Promise
    return async function() {
        logDebug('[聊天自动备份] 触发防抖备份函数');
        clearTimeout(timeout);
        timeout = setTimeout(async () => {
            logDebug('[聊天自动备份] 执行延迟的备份操作 (防抖)');
            try {
                await performBackup();
            } catch (error) {
                console.error('[聊天自动备份] 防抖备份执行出错:', error);
            }
        }, delay);
    };
}

// --- 手动备份 ---
async function performManualBackup() {
    console.log('[聊天自动备份] 执行手动备份');
    try {
        await performBackup();
        toastr.success('已手动备份当前聊天', '聊天自动备份');
        updateBackupsList(); // 刷新列表
    } catch (error) {
        console.error('[聊天自动备份] 手动备份失败:', error);
        toastr.error('手动备份失败，详情请看控制台', '聊天自动备份');
    }
}

// --- 恢复逻辑 (基本不变, 但优化了错误处理) ---
async function restoreBackup(backupData) {
    console.log('[聊天自动备份] 开始恢复备份:', { chatKey: backupData.chatKey, timestamp: backupData.timestamp });
    const context = getContext();
    const isGroup = backupData.chatKey.startsWith('group_');
    const entityIdMatch = backupData.chatKey.match(isGroup ? /group_(\w+)_/ : /char_(\d+)_/);
    const entityId = entityIdMatch ? entityIdMatch[1] : null;

    if (!entityId) {
        console.error('[聊天自动备份] 无法从备份数据中提取角色/群组ID:', backupData.chatKey);
        toastr.error('无法识别备份对应的角色/群组ID');
        return false;
    }

    logDebug(`恢复目标: ${isGroup ? '群组' : '角色'} ID: ${entityId}`);

    // 包装恢复过程，以便统一处理错误
    try {
        // 1. 切换角色/群组 (使用 try...catch 块)
        try {
            if (isGroup) {
                logDebug(`切换到群组: ${entityId}`);
                await context.openGroupChat(entityId);
            } else {
                const charId = parseInt(entityId);
                if (isNaN(charId)) throw new Error(`无效的角色ID: ${entityId}`);
                logDebug(`切换到角色: ${charId}`);
                // 假设 SillyTavern 内部 API 存在且工作正常
                 await jQuery.ajax({
                    type: 'POST',
                    url: '/selectcharacter', // SillyTavern 的端点可能会变
                    data: JSON.stringify({ avatar_url: `${charId}.png` }), // 需要确认选择角色的正确参数
                    contentType: 'application/json',
                });
                // 等待切换完成
                 await new Promise(resolve => setTimeout(resolve, 300));
                 // 更新上下文以反映切换后的状态 (可能需要，取决于 ST 内部机制)
                 // context = getContext(); // 如果 getContext 能实时更新
            }
        } catch (switchError) {
             console.error('[聊天自动备份] 切换角色/群组失败:', switchError);
             toastr.error(`切换到 ${isGroup ? '群组' : '角色'} ${entityId} 失败`);
             return false;
        }


        // 2. 创建新聊天 (使用 try...catch 块)
        try {
            logDebug('创建新的聊天');
             // 统一使用 /newchat API (假设它能处理当前选定的角色/群组)
             await jQuery.ajax({
                type: 'POST',
                url: '/newchat', // 通用创建新聊天的端点
                 beforeSend: (xhr) => {
                    const headers = context.getRequestHeaders?.(); // 检查函数是否存在
                    if (headers) {
                        Object.entries(headers).forEach(([key, value]) => {
                            xhr.setRequestHeader(key, value);
                        });
                    }
                }
            });
            // 等待新聊天创建和加载
            await new Promise(resolve => setTimeout(resolve, 500));
        } catch (newChatError) {
            console.error('[聊天自动备份] 创建新聊天失败:', newChatError);
            toastr.error('创建新聊天失败');
            return false;
        }

        // 重新获取上下文，确保拿到新聊天的状态
        const newContext = getContext();

        // 3. 恢复聊天内容
        logDebug('开始恢复聊天消息, 数量:', backupData.chat.length);
        newContext.chat.length = 0; // 清空当前（新创建的）聊天
        backupData.chat.forEach(msg => newContext.chat.push(msg)); // 填充备份的消息

        // 4. 恢复元数据 (如果存在)
        if (backupData.metadata && typeof newContext.updateChatMetadata === 'function') {
            logDebug('恢复聊天元数据:', backupData.metadata);
            newContext.updateChatMetadata(backupData.metadata, true); // 假设第二个参数是覆盖模式
        } else {
             logDebug('无元数据或 updateChatMetadata 方法不可用，跳过元数据恢复');
        }


        // 5. 保存恢复的聊天
        if (typeof newContext.saveChatConditional === 'function') {
            logDebug('保存恢复后的聊天');
            await newContext.saveChatConditional();
        } else {
             console.warn('[聊天自动备份] saveChatConditional 方法不可用，无法保存恢复的聊天');
        }

        // 6. 触发UI更新
        logDebug('触发聊天加载事件以更新UI');
        if (newContext.eventSource && typeof newContext.eventSource.emit === 'function') {
             // 触发核心的聊天加载事件，让SillyTavern重新渲染
             // 注意：事件名称 'chatLoaded' 是假设的，可能需要用 ST 实际使用的事件
            newContext.eventSource.emit(event_types.CHAT_LOADED || 'chatLoaded');
            // 强制刷新UI (如果上述事件不足够)
             // newContext.printMessages(); // 如果 printMessages 可直接调用
        } else {
            console.warn('[聊天自动备份] 无法触发聊天加载事件，UI可能不会自动更新');
            // 可以尝试强制页面刷新作为后备，但这体验不好
            // location.reload();
             toastr.info('恢复完成，可能需要手动刷新页面查看结果', '聊天自动备份');
        }

        console.log('[聊天自动备份] 聊天恢复成功');
        return true;

    } catch (error) {
        console.error('[聊天自动备份] 恢复聊天过程中发生严重错误:', error);
        toastr.error(`恢复失败: ${error.message}`, '聊天自动备份');
        return false;
    }
}

// --- UI 更新 (优化版) ---
async function updateBackupsList() {
    console.log('[聊天自动备份] 开始更新备份列表UI');
    const backupsContainer = $('#chat_backup_list');
    if (!backupsContainer.length) {
        console.warn('[聊天自动备份] 找不到备份列表容器元素 #chat_backup_list');
        return;
    }

    backupsContainer.html('<div class="backup_empty_notice">正在加载备份...</div>');

    try {
        const allBackups = await getAllBackups();
        backupsContainer.empty(); // 清空

        if (allBackups.length === 0) {
            backupsContainer.append('<div class="backup_empty_notice">暂无保存的备份</div>');
            return;
        }

        // 按时间降序排序
        allBackups.sort((a, b) => b.timestamp - a.timestamp);
        logDebug(`渲染 ${allBackups.length} 个备份`);

        allBackups.forEach(backup => {
            const date = new Date(backup.timestamp);
            // 使用更可靠和本地化的格式
            const formattedDate = date.toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'medium' });

            const backupItem = $(`
                <div class="backup_item">
                    <div class="backup_info">
                        <div class="backup_header">
                            <span class="backup_entity" title="${backup.entityName}">${backup.entityName || '未知实体'}</span>
                            <span class="backup_chat" title="${backup.chatName}">${backup.chatName || '未知聊天'}</span>
                        </div>
                         <div class="backup_details">
                            <span class="backup_mesid">消息数: ${backup.lastMessageId + 1}</span>
                            <span class="backup_date">${formattedDate}</span>
                        </div>
                        <div class="backup_preview" title="${backup.lastMessagePreview}">预览: ${backup.lastMessagePreview}...</div>
                    </div>
                    <div class="backup_actions">
                        <button class="menu_button backup_restore" title="恢复此备份到新聊天" data-timestamp="${backup.timestamp}" data-key="${backup.chatKey}">恢复</button>
                        <button class="menu_button danger_button backup_delete" title="删除此备份" data-timestamp="${backup.timestamp}" data-key="${backup.chatKey}">删除</button>
                    </div>
                </div>
            `);
            backupsContainer.append(backupItem);
        });

        console.log('[聊天自动备份] 备份列表渲染完成');
    } catch (error) {
        console.error('[聊天自动备份] 更新备份列表失败:', error);
        backupsContainer.html(`<div class="backup_empty_notice">加载备份列表失败: ${error.message}</div>`);
    }
}

// --- 初始化与事件绑定 ---
jQuery(async () => {
    console.log('[聊天自动备份] 插件加载中...');

    // 初始化设置
    const settings = initSettings();

    try {
        // 初始化数据库
        await initDatabase();

        // --- 创建 Web Worker ---
        try {
             // 定义 Worker 内部代码
            const workerCode = `
                // Worker Scope
                ${deepCopyLogicString} // 注入深拷贝函数

                self.onmessage = function(e) {
                    const { id, payload } = e.data;
                    // console.log('[Worker] Received message with ID:', id);
                    if (!payload) {
                         // console.error('[Worker] Invalid payload received');
                         self.postMessage({ id, error: 'Invalid payload received by worker' });
                         return;
                    }
                    try {
                        const copiedChat = payload.chat ? deepCopy(payload.chat) : null;
                        const copiedMetadata = payload.metadata ? deepCopy(payload.metadata) : null;
                        // console.log('[Worker] Deep copy successful for ID:', id);
                        self.postMessage({ id, result: { chat: copiedChat, metadata: copiedMetadata } });
                    } catch (error) {
                        // console.error('[Worker] Error during deep copy for ID:', id, error);
                        self.postMessage({ id, error: error.message || 'Worker deep copy failed' });
                    }
                };
            `;
            const blob = new Blob([workerCode], { type: 'application/javascript' });
            backupWorker = new Worker(URL.createObjectURL(blob));
            console.log('[聊天自动备份] Web Worker 已创建');

            // 设置 Worker 消息处理器 (主线程)
            backupWorker.onmessage = function(e) {
                const { id, result, error } = e.data;
                // logDebug(`[主线程] 从 Worker 收到消息 (ID: ${id})`);
                if (workerPromises[id]) {
                    if (error) {
                        console.error(`[主线程] Worker 返回错误 (ID: ${id}):`, error);
                        workerPromises[id].reject(new Error(error));
                    } else {
                        // logDebug(`[主线程] Worker 返回结果 (ID: ${id})`);
                        workerPromises[id].resolve(result);
                    }
                    delete workerPromises[id]; // 清理 Promise 记录
                } else {
                     console.warn(`[主线程] 收到未知或已处理的 Worker 消息 (ID: ${id})`);
                }
            };

            // 设置 Worker 错误处理器 (主线程)
            backupWorker.onerror = function(error) {
                console.error('[聊天自动备份] Web Worker 发生错误:', error);
                 // Reject any pending promises
                 Object.keys(workerPromises).forEach(id => {
                     workerPromises[id].reject(new Error('Worker encountered an unrecoverable error.'));
                     delete workerPromises[id];
                 });
                toastr.error('备份 Worker 发生错误，自动备份可能已停止', '聊天自动备份');
                 // 可以考虑在这里尝试重建 Worker
            };

        } catch (workerError) {
            console.error('[聊天自动备份] 创建 Web Worker 失败:', workerError);
            backupWorker = null; // 确保 worker 实例为空
            toastr.error('无法创建备份 Worker，将回退到主线程备份（性能较低）', '聊天自动备份');
            // 在这种情况下，performDeepCopyInWorker 需要一个回退机制（或插件应禁用/报错）
            // 暂时简化处理：如果Worker创建失败，备份功能将出错
        }


        // 加载插件UI
        const settingsHtml = await renderExtensionTemplateAsync(
            `third-party/${PLUGIN_NAME}`,
            'settings'
        );
        $('#extensions_settings').append(settingsHtml);
        console.log('[聊天自动备份] 已添加设置界面');

        // --- 使用事件委托绑定UI事件 ---
        $(document).on('click', '#chat_backup_manual_backup', performManualBackup);

        // 恢复按钮
        $(document).on('click', '.backup_restore', async function() {
            const button = $(this);
            const timestamp = parseInt(button.data('timestamp'));
            const chatKey = button.data('key');
            logDebug(`点击恢复按钮, timestamp: ${timestamp}, chatKey: ${chatKey}`);

            button.prop('disabled', true).text('恢复中...'); // 禁用按钮并显示状态

            try {
                const db = await getDB();
                const backup = await new Promise((resolve, reject) => {
                    const transaction = db.transaction([STORE_NAME], 'readonly');
                    
                    transaction.onerror = (event) => {
                        reject(event.target.error);
                    };
                    
                    const store = transaction.objectStore(STORE_NAME);
                    const request = store.get([chatKey, timestamp]);
                    
                    request.onsuccess = () => {
                        resolve(request.result);
                    };
                    
                    request.onerror = (event) => {
                        reject(event.target.error);
                    };
                });

                if (backup) {
                    if (confirm(`确定要恢复 "${backup.entityName} - ${backup.chatName}" 的备份吗？\n\n这将选中对应的角色/群组，并创建一个【新的聊天】来载入备份内容。\n当前聊天内容不会丢失，但请确保已保存。`)) {
                        const success = await restoreBackup(backup);
                        if (success) {
                            toastr.success('聊天记录已成功恢复到新聊天');
                        }
                    }
                } else {
                    console.error('[聊天自动备份] 找不到指定的备份:', { timestamp, chatKey });
                    toastr.error('找不到指定的备份');
                }
            } catch (error) {
                console.error('[聊天自动备份] 恢复过程中出错:', error);
                toastr.error(`恢复过程中出错: ${error.message}`);
            } finally {
                button.prop('disabled', false).text('恢复'); // 恢复按钮状态
            }
        });

        // 删除按钮
        $(document).on('click', '.backup_delete', async function() {
            const button = $(this);
            const timestamp = parseInt(button.data('timestamp'));
            const chatKey = button.data('key');
            logDebug(`点击删除按钮, timestamp: ${timestamp}, chatKey: ${chatKey}`);

            const backupItem = button.closest('.backup_item');
            const entityName = backupItem.find('.backup_entity').text();
            const chatName = backupItem.find('.backup_chat').text();
            const date = backupItem.find('.backup_date').text();

            if (confirm(`确定要永久删除这个备份吗？\n\n实体: ${entityName}\n聊天: ${chatName}\n时间: ${date}\n\n此操作无法撤销！`)) {
                button.prop('disabled', true).text('删除中...');
                try {
                    await deleteBackup(chatKey, timestamp);
                    toastr.success('备份已删除');
                    backupItem.fadeOut(300, function() { $(this).remove(); }); // 平滑移除条目
                    // 可选：如果列表为空，显示提示
                    if ($('#chat_backup_list .backup_item').length <= 1) { // <=1 因为当前这个还在DOM里，将要移除
                        updateBackupsList(); // 重新加载以显示"无备份"提示
                    }
                } catch (error) {
                    console.error('[聊天自动备份] 删除备份失败:', error);
                    toastr.error(`删除备份失败: ${error.message}`);
                    button.prop('disabled', false).text('删除');
                }
            }
        });


        // 调试开关
        $(document).on('change', '#chat_backup_debug_toggle', function() {
            settings.debug = $(this).prop('checked');
            console.log('[聊天自动备份] 调试模式已' + (settings.debug ? '启用' : '禁用'));
            saveSettingsDebounced(); // 保存设置
        });

        // 初始化UI状态 (延迟确保DOM渲染完毕)
        setTimeout(async () => {
            $('#chat_backup_debug_toggle').prop('checked', settings.debug);
            await updateBackupsList();
        }, 300);


        // --- 设置优化后的事件监听 ---
        function setupBackupEvents() {
             const immediateBackupEvents = [
                event_types.MESSAGE_SENT,     // 用户发送消息后
                event_types.GENERATION_ENDED, // AI生成完成并添加消息后
                event_types.MESSAGE_SWIPED,   // 用户切换AI回复后
                // event_types.CHAT_DELETED,  // 暂时不监听
            ];

            const debouncedBackupEvents = [
                event_types.MESSAGE_EDITED,   // 编辑消息后 (防抖)
                event_types.MESSAGE_DELETED,  // 删除消息后 (防抖)
                event_types.GROUP_UPDATED,    // 群组信息更新 (防抖, 如果需要)
                event_types.CHAT_CHANGED,     // 作为一个包罗万象的事件，防抖处理可能涵盖其他未明确列出的更改
            ];

            console.log('[聊天自动备份] 设置立即备份事件监听:', immediateBackupEvents);
            immediateBackupEvents.forEach(eventType => {
                 if (!eventType) {
                     console.warn('[聊天自动备份] 检测到未定义的立即备份事件类型');
                     return;
                 }
                eventSource.on(eventType, () => {
                    logDebug(`事件触发 (立即备份): ${eventType}`);
                    performBackup().catch(error => { // 确保捕获立即备份中的异步错误
                         console.error(`[聊天自动备份] 立即备份事件 ${eventType} 处理失败:`, error);
                    });
                });
            });

            const debouncedBackup = createDebouncedBackup(2000); // 2秒防抖
            console.log('[聊天自动备份] 设置防抖备份事件监听:', debouncedBackupEvents);
            debouncedBackupEvents.forEach(eventType => {
                 if (!eventType) {
                     console.warn('[聊天自动备份] 检测到未定义的防抖备份事件类型');
                     return;
                 }
                eventSource.on(eventType, () => {
                    logDebug(`事件触发 (防抖备份): ${eventType}`);
                    debouncedBackup(); // 调用防抖函数
                });
            });

            console.log('[聊天自动备份] 事件监听器设置完成');
        }

        setupBackupEvents(); // 应用新的事件绑定逻辑

        // 监听扩展页面打开事件，刷新列表 (使用事件委托)
        $(document).on('click', '#extensions_popup > .popup_header > .popup_close', () => {
            // 扩展页面通常通过点击外部或关闭按钮关闭，但打开是通过 #extensionsMenuButton
            // 监听打开按钮更可靠
        });
        $(document).on('click', '#extensionsMenuButton', () => {
             if ($('#chat_auto_backup_settings').is(':visible')) {
                 console.log('[聊天自动备份] 扩展菜单按钮点击，且本插件设置可见，刷新备份列表');
                 setTimeout(updateBackupsList, 200); // 稍作延迟确保面板内容已加载
             }
        });
        // 同时，在抽屉打开时也刷新
        $(document).on('click', '#chat_auto_backup_settings .inline-drawer-toggle', function() {
            const drawer = $(this).closest('.inline-drawer');
            // 检查抽屉是否即将打开 (基于当前是否有 open class)
            if (!drawer.hasClass('open')) {
                 console.log('[聊天自动备份] 插件设置抽屉打开，刷新备份列表');
                 setTimeout(updateBackupsList, 50); // 几乎立即刷新
            }
        });


        // 初始备份检查 (延迟执行，确保聊天已加载)
        setTimeout(async () => {
            logDebug('[聊天自动备份] 执行初始备份检查');
            const context = getContext();
            if (context.chat && context.chat.length > 0) {
                logDebug('[聊天自动备份] 发现现有聊天记录，执行初始备份');
                try {
                    await performBackup();
                } catch (error) {
                    console.error('[聊天自动备份] 初始备份执行失败:', error);
                }
            } else {
                logDebug('[聊天自动备份] 当前没有聊天记录，跳过初始备份');
            }
        }, 4000); // 稍长延迟，等待应用完全初始化

        console.log('[聊天自动备份] 插件加载完成');

    } catch (error) {
        console.error('[聊天自动备份] 插件加载过程中发生严重错误:', error);
        // 可以在UI上显示错误信息
        $('#extensions_settings').append(
            '<div class="error">聊天自动备份插件加载失败，请检查控制台。</div>'
        );
    }
});
