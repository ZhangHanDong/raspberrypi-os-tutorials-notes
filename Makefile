.PHONY: deploy

init:
	git worktree remove -f /tmp/osbook
	git worktree add -f /tmp/osbook gh-pages

deploy: init
	@echo "====> deploying to github"
	mdbook build
	rm -rf /tmp/osbook/*
	cp -rp book/* /tmp/osbook/
	rm -rf book/*
	cd /tmp/osbook && \
		git add -A && \
		git commit -m "deployed on $(shell date) by ${USER}" && \
		git push -f notes gh-pages