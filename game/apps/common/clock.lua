-- Demo app: prints the in-game time every 5 seconds.
-- Proves the kernel can run this alongside other tasks (e.g. raytower)
-- without blocking them.

while true do
    print("[clock] " .. textutils.formatTime(os.time(), true))
    os.sleep(5)
end
