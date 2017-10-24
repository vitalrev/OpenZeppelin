var OurToken = artifacts.require("OurToken");

module.exports = function(deployer, network, accounts) {
  deployer.deploy(OurToken, accounts[0], accounts[0], accounts[0], accounts[0]);
};